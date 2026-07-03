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
