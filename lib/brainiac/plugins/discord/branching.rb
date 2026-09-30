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
      module Branching
        class << self
          # Fork a conversation from a message into a new thread.
          #
          # @param channel_id [String] The channel where the message lives
          # @param message_id [String] The message to branch from
          # @param topic [String, nil] Optional thread title (defaults to message content snippet)
          # @param agent_key [String] The agent handling this branch
          # @param agent_name [String] Display name of the agent
          # @param bot_token [String] Discord bot token
          # @param project_key [String, nil] Optional project to inherit (not locked until implementation)
          # @return [Hash, nil] The created thread object, or nil on failure
          def fork_conversation(channel_id:, message_id:, topic: nil, agent_key:, agent_name:, bot_token:, project_key: nil)
            # Fetch the source message to get its content for the thread title
            source_message = Api.fetch_message(channel_id, message_id, token: bot_token)
            unless source_message
              LOG.warn "[Discord:#{agent_name}] Cannot fork — failed to fetch message #{message_id}" if defined?(LOG)
              return nil
            end

            # Build thread title
            content = source_message["content"]&.strip || ""
            content = strip_inline_tags(content)
            thread_title = build_thread_title(topic, content, agent_name)

            # Create the thread
            thread = Api.create_thread(channel_id, message_id, name: thread_title, token: bot_token)
            unless thread && thread["id"]
              LOG.error "[Discord:#{agent_name}] Failed to create branch thread from message #{message_id}" if defined?(LOG)
              return nil
            end

            thread_id = thread["id"]
            LOG.info "[Discord:#{agent_name}] Created branch thread #{thread_id}: \"#{thread_title}\"" if defined?(LOG)

            # Register as an unbound branch (no worktree yet)
            register_unbound_branch(
              agent_key: agent_key, agent_name: agent_name,
              thread_id: thread_id, project_key: project_key,
              source_channel_id: channel_id, source_message_id: message_id
            )

            # React on the source message to indicate branching
            Thread.new { Api.add_reaction(channel_id, message_id, "🌿", token: bot_token) }

            # Post an intro message in the new thread
            post_branch_intro(thread_id, agent_name, bot_token)

            thread
          end

          private

          # Strip inline tags from content for cleaner thread titles.
          def strip_inline_tags(content)
            content
              .gsub(/\[(?:fork|branch|project|effort|cli|profile|p|deploy|chat|question|\?|fresh|plan|worktree|workitem)(?::[^\]]+)?\]/i, "")
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
        end
      end
    end
  end
end
