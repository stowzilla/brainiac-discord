# frozen_string_literal: true

require "fileutils"

module Brainiac
  module Plugins
    module Discord
      # Discord draft delivery system.
      #
      # Response files land in draft/ with a .meta.json sidecar containing delivery info.
      # After successful posting, both files move to posted/.
      # A poller thread recovers orphaned drafts (e.g. after a server restart).
      module Delivery
        BRAINIAC_DIR_PATH = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        DRAFT_DIR  = File.join(BRAINIAC_DIR_PATH, "tmp", "discord", "draft")
        POSTED_DIR = File.join(BRAINIAC_DIR_PATH, "tmp", "discord", "posted")

        POLLER_INTERVAL = 5   # seconds
        DRAFT_MIN_AGE = 30    # seconds — don't race the monitoring thread

        # Shared thread map: when multiple agents are mentioned in the same message,
        # the first to deliver creates the thread and stores its ID here so the rest
        # post into the same thread instead of creating duplicates.
        @shared_threads = {}
        @shared_threads_mutex = Mutex.new

        class << self
          attr_reader :shared_threads, :shared_threads_mutex

          def ensure_dirs!
            FileUtils.mkdir_p(DRAFT_DIR)
            FileUtils.mkdir_p(POSTED_DIR)
          end

          def start_poller!
            ensure_dirs!
            Thread.new do
              LOG.info "[Discord] Draft poller started, checking #{DRAFT_DIR} every #{POLLER_INTERVAL}s" if defined?(LOG)
              loop do
                sleep POLLER_INTERVAL
                poll_drafts
              rescue StandardError => e
                LOG.error "[Discord] Draft poller error: #{e.message}" if defined?(LOG)
              end
            end
          end

          # Shared logic for posting a draft response file to Discord and moving it to posted/.
          def deliver_draft(response_file, meta_file)
            return false unless File.exist?(meta_file)

            lock_file = "#{meta_file}.lock"
            begin
              File.open(lock_file, File::CREAT | File::EXCL | File::WRONLY) {} # rubocop:disable Lint/EmptyBlock
            rescue Errno::EEXIST
              return false
            end

            meta = JSON.parse(File.read(meta_file))
            bot_token = resolve_bot_token(meta["agent_key"], meta["agent_name"])

            unless bot_token
              FileUtils.rm_f(lock_file)
              return false
            end

            unless File.exist?(response_file)
              FileUtils.rm_f(lock_file)
              return false
            end

            deliver_response_content(response_file, meta, bot_token)
            archive_delivered(response_file, meta_file, lock_file, meta["agent_name"])
            true
          rescue StandardError => e
            LOG.error "[Discord] Failed to deliver draft #{meta_file}: #{e.message}" if defined?(LOG)
            File.delete(lock_file) if lock_file && File.exist?(lock_file)
            false
          end

          private

          def poll_drafts
            # Clean up stale lock files (older than 60s) left by crashed deliveries
            Dir.glob(File.join(DRAFT_DIR, "*.lock")).each do |lock_file|
              File.delete(lock_file) if (Time.now - File.mtime(lock_file)) > 60
            end

            Dir.glob(File.join(DRAFT_DIR, "*.meta.json")).each do |meta_file|
              next if (Time.now - File.mtime(meta_file)) < DRAFT_MIN_AGE

              response_file = if meta_file.end_with?(".md.meta.json")
                                meta_file.sub(".md.meta.json", ".md")
                              else
                                meta_file.sub(".meta.json", ".md")
                              end
              next unless File.exist?(response_file)

              LOG.info "[Discord] Poller recovering orphaned draft: #{File.basename(meta_file)}" if defined?(LOG)
              deliver_draft(response_file, meta_file)
            end
          end

          def resolve_bot_token(agent_key, agent_name)
            token = Gateway.bot_token(agent_key)
            token ||= (AGENT_REGISTRY.dig(agent_key, "env") || {})["DISCORD_BOT_TOKEN"]
            LOG.warn "[Discord:#{agent_name}] No bot token found for #{agent_key}, cannot deliver draft" if !token && defined?(LOG)
            token
          end

          def deliver_response_content(response_file, meta, bot_token)
            channel_id = meta["channel_id"]
            message_id = meta["message_id"]
            agent_key = meta["agent_key"]
            agent_name = meta["agent_name"]
            response = File.read(response_file).strip

            if response.empty?
              Api.add_reaction(channel_id, message_id, "😶", token: bot_token) if message_id
              Api.send_message(channel_id, "_#{agent_name} had nothing to say._", token: bot_token)
            elsif meta["is_dm"] || meta["is_thread"] || message_id.nil?
              deliver_to_dm_or_forum(response, channel_id, message_id, agent_name, meta, bot_token)
            else
              deliver_to_channel_thread(response, channel_id, message_id, agent_key, agent_name, meta["clean_content"] || "", bot_token)
            end
          end

          def archive_delivered(response_file, meta_file, lock_file, agent_name)
            FileUtils.mv(response_file, File.join(POSTED_DIR, File.basename(response_file))) if File.exist?(response_file)
            FileUtils.mv(meta_file, File.join(POSTED_DIR, File.basename(meta_file)))
            FileUtils.rm_f(lock_file)
            LOG.info "[Discord:#{agent_name}] Draft delivered and moved to posted/" if defined?(LOG)
          end

          def deliver_to_dm_or_forum(response, channel_id, message_id, agent_name, meta, bot_token)
            if message_id.nil? && Api.forum_channel?(channel_id, token: bot_token)
              title = meta["forum_title"] || "#{agent_name} — #{Time.now.strftime("%b %d, %Y")}"
              if meta["forum_reply_to_latest"]
                latest_thread = Api.find_latest_forum_thread(channel_id, token: bot_token)
                if latest_thread
                  Api.send_long_message(latest_thread["id"], response, token: bot_token)
                else
                  LOG.warn "[Discord:#{agent_name}] No existing thread found, creating new forum post" if defined?(LOG)
                  Api.create_forum_post(channel_id, title: title, content: response, token: bot_token)
                end
              else
                Api.create_forum_post(channel_id, title: title, content: response, token: bot_token)
              end
            else
              Api.send_long_message(channel_id, response, token: bot_token)
            end
          end

          def deliver_to_channel_thread(response, channel_id, message_id, agent_key, agent_name, clean_content, bot_token)
            thread_id = nil
            created_thread = false

            @shared_threads_mutex.synchronize do
              thread_id = @shared_threads[message_id]

              unless thread_id
                original_msg = Api.request(:get, "/channels/#{channel_id}/messages/#{message_id}", token: bot_token)
                if original_msg&.dig("thread", "id")
                  thread_id = original_msg["thread"]["id"]
                  @shared_threads[message_id] = thread_id
                  LOG.info "[Discord:#{agent_name}] Discovered existing thread #{thread_id} on message #{message_id} via API" if defined?(LOG)
                end
              end

              unless thread_id
                display_name = agent_display_name(agent_key)
                thread = Api.create_thread(channel_id, message_id, name: "#{display_name}: #{clean_content[0..80]}", token: bot_token)
                if thread && thread["id"]
                  thread_id = thread["id"]
                  @shared_threads[message_id] = thread_id
                  created_thread = true
                  LOG.info "[Discord:#{agent_name}] Created shared thread #{thread_id} for message #{message_id}" if defined?(LOG)
                end
              end
            end

            if thread_id
              LOG.info "[Discord:#{agent_name}] Joining shared thread #{thread_id} for message #{message_id}" if !created_thread && defined?(LOG)

              # Propagate dispatch depth to the thread
              propagate_dispatch_depth(channel_id, thread_id, agent_name)

              Api.send_typing(thread_id, token: bot_token)
              Api.send_long_message(thread_id, response, token: bot_token)
            else
              LOG.warn "[Discord:#{agent_name}] Thread creation failed, falling back to reply" if defined?(LOG)
              Api.send_long_message(channel_id, response, token: bot_token, reply_to: message_id)
            end
          end

          def propagate_dispatch_depth(channel_id, thread_id, agent_name)
            return unless defined?(AGENT_DISPATCH_DEPTH) && respond_to?(:record_human_comment)

            parent_depth_key = "discord-#{channel_id}"
            thread_depth_key = "discord-#{thread_id}"
            parent_info = AGENT_DISPATCH_DEPTH[parent_depth_key]
            return if AGENT_DISPATCH_DEPTH[thread_depth_key]

            if parent_info
              AGENT_DISPATCH_DEPTH[thread_depth_key] = { count: 0, last_human_at: parent_info[:last_human_at] }
              LOG.info "[Discord:#{agent_name}] Propagated dispatch depth from channel #{channel_id} to thread #{thread_id}" if defined?(LOG)
            else
              record_human_comment(thread_depth_key)
            end
          end
        end
      end
    end
  end
end
