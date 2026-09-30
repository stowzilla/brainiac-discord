# frozen_string_literal: true

module Brainiac
  module Plugins
    module Discord
      # Conversation branching — fork a conversation into a new thread.
      #
      # Supports two triggers:
      # - 🌿 reaction on any message → creates thread from that message
      # - [fork] or [fork:topic] inline tag → creates thread from the tagged message
      #
      # Branched threads start "unbound" — no worktree, no project lock-in.
      # The agent can discuss, search brain, and read files across any registered project.
      # When implementation work is requested, the worktree is created at that point.
      #
      # Threading limitations:
      # - You can create a thread from a message in a regular text channel
      # - You CANNOT create a thread from a message inside an existing thread
      # - When the source message is in a thread, we create a standalone thread in the parent channel
      module Branching
        class << self
          # Fork a conversation from a message into a new thread.
          #
          # @param source_channel_id [String] The channel where the source message lives
          # @param source_message_id [String] The message to branch from
          # @param source_message [Hash, nil] The source message object (avoids re-fetch if already have it)
          # @param source_is_thread [Boolean] Whether the source channel is a thread
          # @param parent_channel_id [String] The parent text channel (same as source if not in a thread)
          # @param topic [String, nil] Optional thread title (defaults to message content snippet)
          # @param agent_key [String] The agent handling this branch
          # @param agent_name [String] Display name of the agent
          # @param bot_token [String] Discord bot token
          # @param project_key [String, nil] Optional project to inherit (not locked until implementation)
          # @return [Hash, nil] The created thread object, or nil on failure
          def fork_conversation(source_channel_id:, source_message_id:, agent_key:, agent_name:, bot_token:,
                                source_message: nil, source_is_thread: false, parent_channel_id: nil,
                                topic: nil, project_key: nil)
            # Fetch the source message if not provided
            source_message ||= Api.fetch_message(source_channel_id, source_message_id, token: bot_token)
            unless source_message
              LOG.warn "[Discord:#{agent_name}] Cannot fork — failed to fetch message #{source_message_id}" if defined?(LOG)
              return nil
            end

            # Build thread title
            content = source_message["content"]&.strip || ""
            content = strip_inline_tags(content)
            thread_title = build_thread_title(topic, content, agent_name)

            # Create the thread
            # If the source message is inside a thread, we can't create a sub-thread from it.
            # Instead, create a standalone thread in the parent channel.
            thread = if source_is_thread && parent_channel_id
                       create_standalone_thread(parent_channel_id, thread_title, agent_name, bot_token)
                     else
                       Api.create_thread(source_channel_id, source_message_id, name: thread_title, token: bot_token)
                     end

            unless thread && thread["id"]
              LOG.error "[Discord:#{agent_name}] Failed to create branch thread from message #{source_message_id}" if defined?(LOG)
              return nil
            end

            thread_id = thread["id"]
            LOG.info "[Discord:#{agent_name}] Created branch thread #{thread_id}: \"#{thread_title}\"" if defined?(LOG)

            # Register as an unbound branch (no worktree yet)
            register_unbound_branch(
              agent_key: agent_key, agent_name: agent_name,
              thread_id: thread_id, project_key: project_key,
              source_channel_id: source_channel_id, source_message_id: source_message_id
            )

            # React on the source message to indicate branching
            Thread.new { Api.add_reaction(source_channel_id, source_message_id, "🌿", token: bot_token) }

            # Post an intro message in the new thread
            # Include a reference to the original message when created as a standalone thread
            if source_is_thread
              post_branch_intro_with_reference(thread_id, agent_name, source_channel_id, source_message_id, bot_token)
            else
              post_branch_intro(thread_id, agent_name, bot_token)
            end

            thread
          end

          # Legacy method signature for backward compatibility with [fork] tag handling.
          # The message.rb handler uses the old parameter names.
          def fork_conversation_legacy(channel_id:, message_id:, agent_key:, agent_name:, bot_token:, topic: nil, project_key: nil)
            fork_conversation(
              source_channel_id: channel_id,
              source_message_id: message_id,
              source_message: nil,
              source_is_thread: false,
              parent_channel_id: channel_id,
              topic: topic,
              agent_key: agent_key,
              agent_name: agent_name,
              bot_token: bot_token,
              project_key: project_key
            )
          end

          private

          # Create a standalone thread (not connected to a message).
          # Used when forking from inside an existing thread.
          # Discord API: POST /channels/<channel_id>/threads
          def create_standalone_thread(channel_id, name, agent_name, bot_token)
            thread_name = name.length > 100 ? "#{name[0..96]}..." : name
            result = Api.request(:post, "/channels/#{channel_id}/threads", token: bot_token, body: {
                                   name: thread_name,
                                   type: 11, # PUBLIC_THREAD
                                   auto_archive_duration: 1440
                                 })

            if result && result["id"]
              LOG.info "[Discord:#{agent_name}] Created standalone thread #{result["id"]} in channel #{channel_id}" if defined?(LOG)
            elsif defined?(LOG)
              LOG.error "[Discord:#{agent_name}] Failed to create standalone thread: #{result.inspect}"
            end

            result
          end

          # Strip inline tags from content for cleaner thread titles.
          #
          # The bracket-tag regex uses an atomic group ((?>...)) around the tag
          # name so the engine can't backtrack into overlapping alternatives on
          # malformed input like "[p:[?:[?:...". Without it, the "p"/"?"
          # alternatives combined with the unbounded [^\]]+ argument create
          # polynomial-time backtracking (ReDoS) on adversarial strings.
          def strip_inline_tags(content)
            content
              .gsub(/\[(?>fork|branch|project|effort|cli|profile|p|deploy|chat|question|\?|fresh|plan|worktree|workitem)(?::[^\]]*)?\]/i, "")
              .gsub(/\[\w+\]/i, "") # Model tags and others
              .gsub(/<@!?\d+>/, "") # Discord mentions
              .strip
          end

          def build_thread_title(topic, content, agent_name)
            if topic && topic != true
              "#{agent_name}: #{topic}"
            elsif !content.empty?
              snippet = content[0..60]
              snippet = "#{snippet}..." if content.length > 60
              "#{agent_name}: #{snippet}"
            else
              "#{agent_name}: Branch"
            end
          end

          def register_unbound_branch(agent_key:, agent_name:, thread_id:, project_key:, source_channel_id:, source_message_id:)
            thread_map_key = "#{agent_key}:#{thread_id}"

            Config.thread_map_mutex.synchronize do
              map = Config.load_thread_map
              map[thread_map_key] = {
                "channel_id" => thread_id,
                "project" => project_key,
                "unbound" => true, # No worktree yet — created on demand
                "source_channel_id" => source_channel_id,
                "source_message_id" => source_message_id,
                "created_at" => Time.now.iso8601
              }
              Config.save_thread_map(map)
            end

            LOG.info "[Discord:#{agent_name}] Registered unbound branch #{thread_map_key} (project: #{project_key || "none"})" if defined?(LOG)
          end

          def post_branch_intro(thread_id, agent_name, bot_token)
            intro = "_Branched conversation. I'll work in this thread — the original stays undisturbed._"
            Api.send_message(thread_id, intro, token: bot_token)
          rescue StandardError => e
            LOG.warn "[Discord:#{agent_name}] Failed to post branch intro: #{e.message}" if defined?(LOG)
          end

          # Post intro with a reference to the original message (for standalone threads).
          def post_branch_intro_with_reference(thread_id, agent_name, source_channel_id, source_message_id, bot_token)
            # Discord message link format: https://discord.com/channels/guild_id/channel_id/message_id
            # For within the same server, we can use a relative link
            message_link = "https://discord.com/channels/@me/#{source_channel_id}/#{source_message_id}"
            intro = "_Branched from [this message](#{message_link}). I'll work in this thread — the original stays undisturbed._"
            Api.send_message(thread_id, intro, token: bot_token)
          rescue StandardError => e
            LOG.warn "[Discord:#{agent_name}] Failed to post branch intro with reference: #{e.message}" if defined?(LOG)
          end
        end
      end
    end
  end
end
