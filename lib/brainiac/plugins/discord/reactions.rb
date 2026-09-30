# frozen_string_literal: true

module Brainiac
  module Plugins
    module Discord
      # Discord reaction handler.
      #
      # Handles MESSAGE_REACTION_ADD events:
      # - ❌ to cancel an active agent session
      # - ❔/❓ to peek at the agent's thinking (last 10/20 lines)
      # - 🧠 to stream the full thinking log to a thread
      # - Non-reserved emojis logged as feedback to the agent's persona
      module Reactions
        # Global deduplication for fork reactions. Tracks which messages have
        # already been forked to prevent duplicates from multiple agents or
        # repeated Discord events.
        #
        # Key: "channel_id:message_id" -> Time the fork was handled
        # Entries expire after 60 seconds (well beyond Discord's duplicate window).
        FORK_DEDUP = {}
        FORK_DEDUP_MUTEX = Mutex.new
        FORK_DEDUP_TTL = 60 # seconds

        class << self
          def handle(reaction_data, agent_key, bot_token, bot_user_id)
            channel_id = reaction_data["channel_id"]
            message_id = reaction_data["message_id"]
            user_id = reaction_data["user_id"]
            emoji = reaction_data["emoji"]
            emoji_name = emoji["name"]

            agent_name = agent_display_name(agent_key) || agent_key.capitalize

            # Ignore reactions from bots (including self)
            return if user_id == bot_user_id

            case emoji_name
            when "❔", "❓"
              handle_thinking_peek(agent_key, agent_name, channel_id, message_id, bot_token, line_count: emoji_name == "❔" ? 10 : 20)
            when "🧠"
              handle_thinking_stream(agent_key, agent_name, channel_id, message_id, bot_token)
            when "❌"
              handle_cancel(agent_key, agent_name, channel_id, message_id, bot_token)
            when "🌿", "🪾", "🍴", "🍽️"
              handle_branch(agent_key, agent_name, channel_id, message_id, bot_token, emoji: emoji_name)
            else
              unless Api::RESERVED_EMOJIS.include?(emoji_name)
                Thread.new do
                  log_emoji_feedback(channel_id, message_id, user_id, emoji_name, agent_key, agent_name, bot_token)
                rescue StandardError => e
                  LOG.warn "[Discord:#{agent_name}] Feedback logging failed: #{e.message}" if defined?(LOG)
                end
              end
            end
          end

          private

          # Strip ANSI escape codes and non-ASCII from log output for Discord display.
          def strip_ansi(text)
            text.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")
                .gsub(/\x1b\[[0-9;]*[a-zA-Z]/, "")
                .gsub(/\e\][0-9;]*.*?(\x07|\e\\)/, "")
                .gsub(/\e[=>]/, "")
                .gsub(/\[\?[0-9]+[lh]/, "")
                .gsub("[K", "")
                .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
                .strip
          end

          def handle_thinking_peek(agent_key, agent_name, channel_id, message_id, bot_token, line_count:)
            session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

            ACTIVE_SESSIONS_MUTEX.synchronize do
              session_info = ACTIVE_SESSIONS[session_key]

              unless session_info
                LOG.info "[Discord:#{agent_name}] Thinking peek on #{message_id} but no active session found" if defined?(LOG)
                return
              end

              log_file = session_info[:log_file]
              unless log_file && File.exist?(log_file)
                LOG.warn "[Discord:#{agent_name}] No log file found for session #{session_key}" if defined?(LOG)
                Api.send_message(channel_id, "No thinking file found for this session.", token: bot_token, reply_to: message_id)
                return
              end

              LOG.info "[Discord:#{agent_name}] Reading last #{line_count} lines from #{log_file}" if defined?(LOG)

              lines = File.readlines(log_file).last(line_count)
              thinking_output = strip_ansi(lines.join)

              response = "**Last #{line_count} lines:**\n```\n#{thinking_output}\n```"
              Api.send_message(channel_id, response, token: bot_token, reply_to: message_id)
            end
          end

          def handle_thinking_stream(agent_key, agent_name, channel_id, message_id, bot_token)
            session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

            ACTIVE_SESSIONS_MUTEX.synchronize do
              session_info = ACTIVE_SESSIONS[session_key]

              unless session_info
                LOG.info "[Discord:#{agent_name}] 🧠 reaction on #{message_id} but no active session found" if defined?(LOG)
                return
              end

              log_file = session_info[:log_file]
              unless log_file && File.exist?(log_file)
                LOG.warn "[Discord:#{agent_name}] No log file found for session #{session_key}" if defined?(LOG)
                Api.send_message(channel_id, "No thinking file found for this session.", token: bot_token, reply_to: message_id)
                return
              end

              LOG.info "[Discord:#{agent_name}] Creating thread and streaming thinking from #{log_file}" if defined?(LOG)

              thread_response = Api.create_thread(channel_id, message_id, name: "🧠 Thinking Stream", token: bot_token)
              unless thread_response && thread_response["id"]
                LOG.error "[Discord:#{agent_name}] Failed to create thread, response: #{thread_response.inspect}" if defined?(LOG)
                return
              end

              thread_id = thread_response["id"]
              stream_thinking_to_thread(log_file, thread_id, bot_token)
            end
          end

          def stream_thinking_to_thread(log_file, thread_id, bot_token)
            thinking_content = strip_ansi(File.read(log_file))

            chunks = []
            current_chunk = ""
            thinking_content.lines.each do |line|
              if current_chunk.length + line.length > 1900
                chunks << current_chunk
                current_chunk = line
              else
                current_chunk += line
              end
            end
            chunks << current_chunk unless current_chunk.empty?

            chunks.each do |chunk|
              Api.send_message(thread_id, "```\n#{chunk}\n```", token: bot_token)
              sleep 0.5
            end
          end

          def handle_cancel(agent_key, agent_name, channel_id, message_id, bot_token)
            session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

            ACTIVE_SESSIONS_MUTEX.synchronize do
              session_info = ACTIVE_SESSIONS[session_key]

              unless session_info
                LOG.info "[Discord:#{agent_name}] ❌ reaction on #{message_id} but no active session found" if defined?(LOG)
                return
              end

              LOG.info "[Discord:#{agent_name}] Cancelling session for message #{message_id} (PID: #{session_info[:pid]})" if defined?(LOG)

              begin
                Process.kill("KILL", session_info[:pid])
                LOG.info "[Discord:#{agent_name}] Killed agent process #{session_info[:pid]}" if defined?(LOG)
              rescue Errno::ESRCH
                LOG.warn "[Discord:#{agent_name}] Process #{session_info[:pid]} already exited" if defined?(LOG)
              rescue Errno::EPERM
                LOG.error "[Discord:#{agent_name}] Permission denied killing process #{session_info[:pid]}" if defined?(LOG)
              end

              ACTIVE_SESSIONS.delete(session_key)

              begin
                Api.remove_reaction(channel_id, message_id, "👀", token: bot_token)
                Api.add_reaction(channel_id, message_id, "🛑", token: bot_token)
              rescue StandardError => e
                LOG.warn "[Discord:#{agent_name}] Failed to update reactions: #{e.message}" if defined?(LOG)
              end

              session_info[:draft_files]&.each { |file| FileUtils.rm_f(file) }
            end
          end

          # Handle fork reactions (🌿, 🪾, 🍴, 🍽️) — fork the conversation into a new thread.
          # The reacted message becomes the root of the new branch.
          #
          # Multi-agent coordination uses a two-phase approach:
          # 1. Global deduplication — atomic check-and-claim ensures only one agent proceeds
          # 2. Ownership check — determines which specific agent should handle it
          #
          # This prevents both the race condition (multiple agents passing ownership check
          # simultaneously) and duplicate events (Discord sending the same reaction multiple times).
          def handle_branch(agent_key, agent_name, channel_id, message_id, bot_token, emoji: "🌿")
            LOG.info "[Discord:#{agent_name}] #{emoji} fork reaction on message #{message_id} in channel #{channel_id}" if defined?(LOG)

            dedup_key = "#{channel_id}:#{message_id}"

            # Fetch source message to determine ownership
            source_message = Api.fetch_message(channel_id, message_id, token: bot_token)
            unless source_message
              LOG.warn "[Discord:#{agent_name}] #{emoji} skipping — couldn't fetch message #{message_id}" if defined?(LOG)
              return
            end

            # Check if this agent should handle the fork (based on mentions/authorship/fallback)
            unless should_handle_fork?(agent_key, source_message)
              LOG.info "[Discord:#{agent_name}] #{emoji} skipping — another agent should handle this fork" if defined?(LOG)
              return
            end

            # Atomic claim — only one agent gets past this point
            unless claim_fork!(dedup_key, agent_key)
              LOG.info "[Discord:#{agent_name}] #{emoji} skipping — fork already claimed by another process" if defined?(LOG)
              return
            end

            LOG.info "[Discord:#{agent_name}] #{emoji} handling fork for message #{message_id}" if defined?(LOG)

            # Check if we're in a thread — get parent channel for project resolution
            channel_info = Api.fetch_channel_info(channel_id, token: bot_token)
            is_thread = channel_info && [11, 12].include?(channel_info["type"])
            parent_channel_id = is_thread ? channel_info["parent_id"] : channel_id

            # Resolve project from channel mapping (inherited, but not locked)
            project_key, _project_config, _mapping = Config.find_project_for_channel(parent_channel_id)

            thread = Branching.fork_conversation(
              source_channel_id: channel_id,
              source_message_id: message_id,
              source_message: source_message,
              source_is_thread: is_thread,
              parent_channel_id: parent_channel_id,
              topic: nil, # Auto-generate from message content
              agent_key: agent_key,
              agent_name: agent_name,
              bot_token: bot_token,
              project_key: project_key,
              fork_emoji: emoji
            )

            Api.add_reaction(channel_id, message_id, "⚠️", token: bot_token) unless thread
          end

          # Atomically claim a fork operation. Returns true if this caller wins,
          # false if already claimed. Cleans up expired entries while holding the lock.
          def claim_fork!(dedup_key, agent_key)
            FORK_DEDUP_MUTEX.synchronize do
              now = Time.now

              # Clean up expired entries
              FORK_DEDUP.delete_if { |_, claimed_at| now - claimed_at > FORK_DEDUP_TTL }

              # Check if already claimed
              return false if FORK_DEDUP.key?(dedup_key)

              # Claim it
              FORK_DEDUP[dedup_key] = now
              LOG.debug "[Discord] Fork claimed: #{dedup_key} by #{agent_key}" if defined?(LOG) && LOG.respond_to?(:debug)
              true
            end
          end

          # Determine if this agent should handle a fork reaction.
          # Only one agent should handle each fork to avoid duplicates.
          def should_handle_fork?(agent_key, source_message)
            bot_user_id = Gateway.bot_user_id(agent_key)&.to_s
            return false unless bot_user_id

            # 1. If this bot authored the message → handle it
            return true if source_message.dig("author", "id").to_s == bot_user_id

            # 2. If this bot was @mentioned in the message → handle it
            mentions = source_message["mentions"] || []
            content = source_message["content"] || ""
            if mentions.any? { |m| m["id"].to_s == bot_user_id } ||
               content.match?(/<@!?#{Regexp.escape(bot_user_id)}>/)
              return true
            end

            # 3. Fallback: deterministic selection among all active bots
            # Pick the bot with the lexicographically smallest agent_key
            active_bot_keys = []
            Gateway.each_bot do |key, info|
              active_bot_keys << key if info[:user_id]
            end

            return false if active_bot_keys.empty?

            # Pick the smallest key to ensure deterministic selection
            designated_handler = active_bot_keys.min
            agent_key == designated_handler
          end

          def log_emoji_feedback(channel_id, message_id, user_id, emoji_name, agent_key, agent_name, bot_token)
            msg = Api.fetch_message(channel_id, message_id, token: bot_token, log_errors: false)
            return unless msg&.dig("author", "bot")

            bot_uid = Gateway.bot_user_id(agent_key)
            return unless bot_uid && msg.dig("author", "id") == bot_uid

            reactor = respond_to?(:find_user_by_discord_id) ? find_user_by_discord_id(user_id) : nil
            reactor_name = reactor ? reactor["canonical_name"] : user_id

            snippet = (msg["content"] || "")[0, 80].tr("\n", " ").strip
            snippet = "#{snippet}..." if (msg["content"] || "").length > 80

            feedback_dir = File.join(persona_dir_for(agent_name), "people")
            FileUtils.mkdir_p(feedback_dir)
            feedback_file = File.join(feedback_dir, "#{reactor_name.downcase.gsub(/[^a-z0-9]/, "-")}-feedback.md")

            timestamp = Time.now.strftime("%Y-%m-%d %H:%M")
            entry = "- #{timestamp} #{emoji_name} on: \"#{snippet}\" (channel: #{channel_id})\n"

            if File.exist?(feedback_file)
              File.open(feedback_file, "a") { |f| f.write(entry) }
            else
              File.write(feedback_file, "# Feedback from #{reactor_name}\n\n## Reaction Log\n#{entry}")
            end

            LOG.info "[Discord:#{agent_name}] Logged #{emoji_name} feedback from #{reactor_name} on message #{message_id}" if defined?(LOG)
          end
        end
      end
    end
  end
end
