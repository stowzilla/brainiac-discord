# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Brainiac
  module Plugins
    module Discord
      # Discord REST API helpers.
      #
      # Low-level HTTP methods and convenience wrappers for the Discord v10 API.
      # Used by the Discord handler itself, but also available for other plugins
      # (e.g. GitHub deploy notifications, Zoho email notifications).
      module Api
        DISCORD_API_BASE = "https://discord.com/api/v10"

        # Emojis reserved for brainiac functionality — not treated as feedback
        RESERVED_EMOJIS = %w[👀 ❌ 🛑 🚫 ⚠️ ⏳ 😶 ❔ ❓ 🧠].freeze

        class << self
          def request(method, path, token:, body: nil, log_errors: true)
            uri = URI("#{DISCORD_API_BASE}#{path}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true

            req = case method
                  when :get    then Net::HTTP::Get.new(uri)
                  when :post   then Net::HTTP::Post.new(uri)
                  when :put    then Net::HTTP::Put.new(uri)
                  when :delete then Net::HTTP::Delete.new(uri)
                  end

            req["Authorization"] = "Bot #{token}"
            req["Content-Type"] = "application/json"
            req.body = body.to_json if body

            response = http.request(req)

            if response.code.to_i == 429
              retry_after = JSON.parse(response.body)["retry_after"] || 1
              LOG.warn "[Discord] Rate limited, waiting #{retry_after}s" if defined?(LOG)
              sleep retry_after
              return request(method, path, token: token, body: body, log_errors: log_errors)
            end

            if response.code.to_i >= 400 && log_errors && defined?(LOG)
              LOG.error "[Discord] API error (#{method} #{path}): HTTP #{response.code} - #{response.body}"
            end

            JSON.parse(response.body) unless response.body.nil? || response.body.empty?
          rescue StandardError => e
            LOG.error "[Discord] API error (#{method} #{path}): #{e.message}" if log_errors && defined?(LOG)
            nil
          end

          # --- Channel & Message Operations ---

          def fetch_channel_history(channel_id, before_message_id, token:, limit: 10)
            messages = request(:get, "/channels/#{channel_id}/messages?before=#{before_message_id}&limit=#{limit}", token: token)

            all_messages = messages.is_a?(Array) ? messages : []

            if all_messages.any?
              oldest = all_messages.last
              all_messages << oldest["referenced_message"] if oldest && oldest["type"] == 21 && oldest["referenced_message"]
            end

            return "" if all_messages.empty?

            lines = all_messages.reverse.filter_map do |msg|
              author = msg.dig("author", "username") || "unknown"
              content = msg["content"]&.strip || ""
              next if content.empty?

              "#{author}: #{content}"
            end

            return "" if lines.empty?

            lines.join("\n")
          rescue StandardError => e
            LOG.warn "[Discord] Failed to fetch channel history: #{e.message}" if defined?(LOG)
            ""
          end

          def fetch_channel_info(channel_id, token:)
            request(:get, "/channels/#{channel_id}", token: token)
          end

          def fetch_message(channel_id, message_id, token:, log_errors: true)
            request(:get, "/channels/#{channel_id}/messages/#{message_id}", token: token, log_errors: log_errors)
          end

          def fetch_guild_member(guild_id, user_id, token:)
            request(:get, "/guilds/#{guild_id}/members/#{user_id}", token: token)
          end

          # --- Messaging ---

          def send_message(channel_id, content, token:, reply_to: nil)
            body = { content: content }
            body[:message_reference] = { message_id: reply_to } if reply_to
            result = request(:post, "/channels/#{channel_id}/messages", token: token, body: body)
            if result && result["id"]
              LOG.info "[Discord] Message posted to channel #{channel_id}, message_id: #{result["id"]}" if defined?(LOG)
            elsif defined?(LOG)
              LOG.error "[Discord] Failed to post message to channel #{channel_id}, result: #{result.inspect}"
            end
            result
          end

          def send_long_message(channel_id, content, token:, reply_to: nil)
            if content.length <= 2000
              send_message(channel_id, content, token: token, reply_to: reply_to)
              return
            end

            chunks = split_content(content)
            chunks.each_with_index do |chunk, i|
              send_message(channel_id, chunk, token: token, reply_to: i.zero? ? reply_to : nil)
              sleep 0.5
            end
          end

          def send_typing(channel_id, token:)
            request(:post, "/channels/#{channel_id}/typing", token: token)
          end

          # --- Reactions ---

          def add_reaction(channel_id, message_id, emoji, token:)
            encoded = URI.encode_www_form_component(emoji)
            request(:put, "/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me", token: token)
          end

          def remove_reaction(channel_id, message_id, emoji, token:)
            encoded = URI.encode_www_form_component(emoji)
            request(:delete, "/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me", token: token)
          end

          # --- Threads & Forums ---

          def create_thread(channel_id, message_id, name:, token:)
            thread_name = name.length > 100 ? "#{name[0..96]}..." : name
            request(:post, "/channels/#{channel_id}/messages/#{message_id}/threads", token: token, body: {
                      name: thread_name,
                      auto_archive_duration: 1440
                    })
          end

          def forum_channel?(channel_id, token:)
            info = fetch_channel_info(channel_id, token: token)
            info && info["type"] == 15
          end

          def find_latest_forum_thread(channel_id, token:)
            channel_info = fetch_channel_info(channel_id, token: token)
            return nil unless channel_info && channel_info["guild_id"]

            guild_id = channel_info["guild_id"]
            result = request(:get, "/guilds/#{guild_id}/threads/active", token: token)
            return nil unless result && result["threads"]

            forum_threads = result["threads"]
                            .select { |t| t["parent_id"] == channel_id }
                            .sort_by { |t| t["id"].to_i }
                            .reverse

            return nil if forum_threads.empty?

            latest = forum_threads.first
            LOG.info "[Discord] Found latest forum thread: #{latest["id"]} (#{latest["name"]}) in channel #{channel_id}" if defined?(LOG)
            latest
          end

          def create_forum_post(channel_id, title:, content:, token:)
            thread_name = title.length > 100 ? "#{title[0..96]}..." : title
            result = request(:post, "/channels/#{channel_id}/threads", token: token, body: {
                               name: thread_name,
                               message: { content: content },
                               auto_archive_duration: 1440
                             })
            if result && result["id"]
              LOG.info "[Discord] Forum post created in channel #{channel_id}, thread_id: #{result["id"]}" if defined?(LOG)
            elsif defined?(LOG)
              LOG.error "[Discord] Failed to create forum post in channel #{channel_id}, result: #{result.inspect}"
            end
            result
          end

          # --- GIF Search ---

          def search_gif(query)
            api_key = Config.giphy_api_key
            return [] unless api_key

            uri = URI("https://api.giphy.com/v1/gifs/search")
            uri.query = URI.encode_www_form(api_key: api_key, q: query, limit: 5, rating: "pg-13")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            response = http.get(uri)
            return [] unless response.code.to_i == 200

            data = JSON.parse(response.body)
            (data["data"] || []).map { |g| { "url" => g.dig("images", "original", "url") || g["url"] } }
          rescue StandardError => e
            LOG.warn "[Discord] GIF search error: #{e.message}" if defined?(LOG)
            []
          end

          # --- Helpers ---

          def find_root_message(message, channel_id, bot_token)
            current_msg = message
            visited = Set.new
            max_depth = 20
            walked = false

            max_depth.times do
              msg_id = current_msg["id"]
              return { id: msg_id, content: nil, author: nil } if visited.include?(msg_id)

              visited << msg_id

              ref = current_msg["message_reference"]
              break unless ref

              ref_msg_id = ref["message_id"]
              ref_channel = ref["channel_id"] || channel_id
              break unless ref_msg_id

              referenced = request(:get, "/channels/#{ref_channel}/messages/#{ref_msg_id}", token: bot_token)
              break unless referenced

              current_msg = referenced
              walked = true
            end

            {
              id: current_msg["id"],
              content: walked ? current_msg["content"]&.strip : nil,
              author: walked ? current_msg.dig("author", "username") : nil
            }
          end

          # Build a Discord mention roster so the agent can @mention people and other bots.
          def mention_roster
            lines = []

            Gateway.each_bot do |agent_key, info|
              next unless info[:user_id]

              display = agent_display_name(agent_key) || agent_key.capitalize
              lines << "  - #{display}: `<@#{info[:user_id]}>`"
            end

            Config.user_mappings.each do |name, discord_id|
              lines << "  - #{name}: `<@#{discord_id}>`"
            end

            lines.join("\n")
          end

          private

          def split_content(content)
            chunks = []
            remaining = content
            while remaining.length.positive?
              if remaining.length <= 2000
                chunks << remaining
                remaining = ""
              else
                split_at = remaining.rindex("\n", 1990) || 1990
                chunks << remaining[0...split_at]
                remaining = remaining[split_at..].lstrip
              end
            end
            chunks
          end
        end
      end
    end
  end
end
