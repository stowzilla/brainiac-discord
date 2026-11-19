# frozen_string_literal: true

module Brainiac
  module Plugins
    module Discord
      # Multi-machine routing for Discord work.
      #
      # Only the leader machine holds the bot gateways, so it hears every message.
      # It decides which machine should do the work and, when that is another
      # machine, hands the raw event over through the brainiac-hub. The machine
      # that receives it runs the agent in its own worktree and posts the reply
      # itself over the REST API.
      #
      # Which machine:
      #   1. `[machine:<name>]` in the message. In a thread this also moves the
      #      thread to that machine.
      #   2. The thread's owner, recorded in the hub as `discord:<agent>:<thread id>`.
      #   3. Otherwise this machine (the leader).
      #
      # Everything here is a no-op without a hub configured.
      module Routing
        MESSAGE_PATH = "/hub/discord/message"
        REACTION_PATH = "/hub/discord/reaction"
        ARCHIVE_PATH = "/hub/discord/thread-archive"
        HANDED_OFF_LIMIT = 1000

        @handed_off = {}
        @claimed = {}
        @mutex = Mutex.new

        class << self
          # True when this machine is a node of a brainiac-hub.
          def active?
            (defined?(Brainiac::Hub) && Brainiac::Hub.respond_to?(:enabled?) && Brainiac::Hub.enabled?) || false
          end

          # This machine's name in the hub, or nil without one.
          def machine
            active? ? Brainiac::Hub.machine_name : nil
          end

          def thread_key(agent_key, thread_id)
            "discord:#{agent_key}:#{thread_id}"
          end

          # --- leader side ---

          # Decide where a message runs. Returns true when it was handed to another
          # machine (or refused with a note in the channel) and the caller must stop.
          #
          # @param requested [String, nil] machine named by a [machine:x] tag
          # @param place [Symbol] :thread, :dm or :channel
          # @param verdict [Hash] what the leader's gates decided (mentioned, own thread, ...)
          def hand_off_message(agent_key:, bot_token:, bot_user_id:, message:, requested:, place:, verdict:)
            return false unless active?

            channel_id = message["channel_id"]
            message_id = message["id"]
            me = machine
            key = work_key(agent_key, place, channel_id, message_id)
            owner = place == :thread ? Brainiac::Hub.owner(key) : nil
            say = ->(text) { Api.send_message(channel_id, text, token: bot_token, reply_to: message_id) }

            requested = settle_request(requested, owner, me, say)
            return true if requested == :refused

            target = requested || owner
            return false if target.nil?

            if target == me
              # A tag naming this machine takes the thread over from its old owner.
              claim_thread(agent_key, channel_id, overwrite: true) if place == :thread && owner != me
              return false
            end

            adopt_thread_depth(channel_id, message_id) if place == :channel
            result = Brainiac::Hub.relay(
              path: MESSAGE_PATH, keys: [key].compact, machine: requested,
              reassign: !requested.nil? && !owner.nil? && requested != owner,
              payload: { "agent_key" => agent_key, "bot_user_id" => bot_user_id,
                         "bot_username" => Gateway.bot_username(agent_key),
                         "from" => me, "message" => message, "verdict" => verdict }
            )
            report_relay(result, target, agent_key, message_id, say)
            true
          end

          # Forward a session reaction (cancel, peek, stream) to the machine the
          # message was handed to. Returns true when it was forwarded.
          def hand_off_reaction(agent_key:, bot_user_id:, reaction:)
            return false unless active?

            target = @mutex.synchronize { @handed_off["#{agent_key}:#{reaction["message_id"]}"] }
            return false unless target && target != machine

            Brainiac::Hub.relay(path: REACTION_PATH, machine: target,
                                payload: { "agent_key" => agent_key, "bot_user_id" => bot_user_id, "reaction" => reaction })
            true
          end

          # A thread this machine has no worktree for was archived or deleted. If
          # another machine owns it, pass the event on so it can clean up.
          def hand_off_archive(agent_key:, data:)
            return false unless active?

            key = thread_key(agent_key, data["id"])
            owner = Brainiac::Hub.owner(key)
            return false unless owner && owner != machine

            Brainiac::Hub.relay(path: ARCHIVE_PATH, keys: [key], payload: { "agent_key" => agent_key, "thread" => data })
            true
          end

          # --- receiving side ---

          def receive_message(payload)
            agent_key, token = receiving_agent(payload)
            return unless token

            verdict = payload["verdict"] || {}
            Message.accept(
              payload["message"], agent_key, token, payload["bot_user_id"],
              mentioned: verdict["mentioned"] ? true : false,
              is_reply_to_bot: verdict["is_reply_to_bot"] ? true : false,
              in_own_thread: verdict["in_own_thread"] ? true : false,
              referenced_message: verdict["referenced_message"], relayed: true
            )
          end

          def receive_reaction(payload)
            agent_key, token = receiving_agent(payload)
            return unless token

            Reactions.handle(payload["reaction"], agent_key, token, payload["bot_user_id"], relayed: true)
          end

          def receive_archive(payload)
            agent_key = payload["agent_key"].to_s
            ThreadCleanup.handle_archive(payload["thread"] || {}, agent_key, agent_display_name(agent_key) || agent_key.capitalize,
                                         relayed: true)
          end

          # --- ownership ---

          # Tell the hub this machine holds a thread's worktree, so follow-ups come
          # back here whichever machine is the leader. Never takes a thread that
          # already has an owner unless overwrite is set.
          #
          # Ownership outlives the worktree on purpose. Discord archives idle
          # threads by itself and cleanup then removes a clean worktree; the next
          # message should still come back to the machine that was chosen. The
          # hub expires an assignment that goes unused.
          def claim_thread(agent_key, thread_id, overwrite: false)
            return unless active? && thread_id

            key = thread_key(agent_key, thread_id)
            return if !overwrite && @mutex.synchronize { @claimed[key] }

            @mutex.synchronize { @claimed[key] = true }
            name = machine
            in_background { Brainiac::Hub.assign([key], name, overwrite: overwrite) }
          end

          def reset!
            @mutex.synchronize do
              @handed_off.clear
              @claimed.clear
            end
          end

          private

          # A thread started from a message has that message's id, so a channel
          # message already knows the key its thread will have.
          def work_key(agent_key, place, channel_id, message_id)
            case place
            when :thread then thread_key(agent_key, channel_id)
            when :channel then thread_key(agent_key, message_id)
            end
          end

          # Check a [machine:x] tag against the machines the hub knows. Returns the
          # machine to ask for, nil to follow the owner, or :refused after telling
          # the user why nothing ran.
          def settle_request(requested, owner, this_machine, say)
            return nil if requested.nil? || requested == owner
            return requested if requested == this_machine

            nodes = (Brainiac::Hub.status || {})["nodes"]
            return requested unless nodes.is_a?(Array) # hub did not answer; the relay will report it

            node = nodes.find { |n| n["name"] == requested }
            unless node
              names = nodes.map { |n| "`#{n["name"]}`" }.join(", ")
              say.call("⚠️ No machine named `#{requested}`. Known machines: #{names}. Nothing ran.")
              return :refused
            end
            return requested if node["online"] || owner.nil?

            # Moving a thread to a machine that is off would let the hub drop it
            # on whichever machine is next in line. Leave it where its work is.
            say.call("⚠️ `#{requested}` is offline, so this thread stays on `#{owner}`.")
            nil
          end

          def report_relay(result, target, agent_key, message_id, say)
            unless result
              say.call("⚠️ Could not reach the hub to pass this to `#{target}`, so nothing ran. Send it again in a moment.")
              return
            end

            taken_by = result["machine"]
            remember_hand_off(agent_key, message_id, taken_by || target)
            if result["status"] == "queued"
              say.call("⏳ `#{taken_by || target}` is offline. This is queued and runs when it is back. " \
                       "To run it elsewhere, send it again with `[machine:<name>]`.")
            elsif taken_by && taken_by != target
              say.call("↪️ `#{target}` did not answer. Running on `#{taken_by}` instead.")
            end
          end

          def remember_hand_off(agent_key, message_id, target)
            @mutex.synchronize do
              @handed_off["#{agent_key}:#{message_id}"] = target
              @handed_off.shift while @handed_off.size > HANDED_OFF_LIMIT
            end
          end

          # The thread a handed-off channel message starts is created on the other
          # machine, so the leader never sees it being made. Give it the parent
          # channel's dispatch-depth record here, or agent-to-agent mentions in
          # that thread are refused until a human speaks in it.
          def adopt_thread_depth(channel_id, message_id)
            return unless defined?(AGENT_DISPATCH_DEPTH)

            parent = AGENT_DISPATCH_DEPTH["discord-#{channel_id}"]
            return unless parent

            AGENT_DISPATCH_DEPTH["discord-#{message_id}"] ||= { count: 0, last_human_at: parent[:last_human_at] }
          end

          def receiving_agent(payload)
            agent_key = payload["agent_key"].to_s
            token = Gateway.token_for(agent_key)
            unless token
              LOG.warn "[Discord] Relayed work for '#{agent_key}' but this machine has no bot token for it — ignoring" if defined?(LOG)
              return [agent_key, nil]
            end

            Gateway.remember_identity(agent_key, user_id: payload["bot_user_id"], username: payload["bot_username"])
            [agent_key, token]
          end

          def in_background
            Thread.new do
              yield
            rescue StandardError => e
              LOG.warn "[Discord] Hub ownership update failed: #{e.message}" if defined?(LOG)
            end
          end
        end
      end
    end
  end
end
