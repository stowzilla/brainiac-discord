# frozen_string_literal: true

require_relative "discord/version"
require_relative "discord/metadata"
require_relative "discord/cli"
require_relative "discord/config"
require_relative "discord/prompts"
require_relative "discord/api"
require_relative "discord/delivery"
require_relative "discord/reactions"
require_relative "discord/message"
require_relative "discord/gateway"

module Brainiac
  module Plugins
    module Discord
      class << self
        # Called by Brainiac plugin system during server startup.
        #
        # @param app [Sinatra::Application] The running Brainiac server
        def register(app)
          # Load Discord config
          Brainiac::Plugins::Discord::Config.load!

          # Register channel prompt
          Brainiac.register_channel_prompt(:discord, Brainiac::Plugins::Discord::Prompts::CHANNEL)

          # Register as notification provider
          register_notification_handler!

          # Register crash handler
          register_crash_handler!

          # Register agent lifecycle hooks
          register_agent_lifecycle_hooks!

          # Start all per-agent Discord bot gateway connections
          Brainiac::Plugins::Discord::Gateway.start_all!

          # Start draft delivery poller
          Brainiac::Plugins::Discord::Delivery.start_poller!

          # Set up API routes
          setup_routes(app)

          LOG.info "[Discord] Plugin registered (#{Brainiac::Plugins::Discord::Gateway.bot_count} bots)"
        end

        private

        def register_agent_lifecycle_hooks!
          Brainiac.on(:agent_added) do |ctx|
            agent_key = ctx[:agent_key]
            entry = ctx[:entry]
            display_name = ctx[:display_name]
            next unless entry.is_a?(Hash)

            token = (entry["env"] || {})["DISCORD_BOT_TOKEN"]
            if token
              # Start a gateway connection for the new agent's bot
              Gateway.start_bot!(agent_key, token)
              LOG.info "[Discord] Started bot for new agent: #{display_name}" if defined?(LOG)
            end
          end

          Brainiac.on(:agent_removed) do |ctx|
            agent_key = ctx[:agent_key]

            # Stop the gateway connection if running
            Gateway.stop_bot!(agent_key)
            LOG.info "[Discord] Stopped bot for removed agent: #{agent_key}" if defined?(LOG)
          end
        end

        def register_notification_handler!
          Brainiac.on(:notify) do |ctx|
            next unless ctx[:channel].to_s == "discord"

            target = ctx[:target]
            message = ctx[:message]
            agent = ctx[:agent]

            agent_key = agent&.downcase&.gsub(/[^a-z0-9-]/, "-")
            token = Gateway.bot_token(agent_key) ||
                    Gateway.discord_bot_tokens[agent_key] ||
                    Gateway.discord_bot_tokens.values.first
            next unless token && target

            # Handle forum posts
            if ctx[:forum_title] && Api.forum_channel?(target, token: token)
              Api.create_forum_post(target, title: ctx[:forum_title], content: message, token: token)
            elsif ctx[:forum_reply_to_latest] && Api.forum_channel?(target, token: token)
              latest = Api.find_latest_forum_thread(target, token: token)
              if latest
                Api.send_long_message(latest["id"], message, token: token)
              else
                Api.send_long_message(target, message, token: token)
              end
            else
              Api.send_long_message(target, message, token: token)
            end

            :discord # Signal that we handled it
          end
        end

        def register_crash_handler!
          Brainiac.on(:agent_crashed) do |ctx|
            next unless %i[discord cron].include?(ctx[:source])

            source_context = ctx[:source_context] || {}
            channel_id = source_context[:channel_id] || source_context.dig(:job, :notify_target) || source_context.dig(:job, :discord_channel_id)
            next unless channel_id

            bot_token = source_context[:bot_token]
            unless bot_token
              agent_key = source_context.dig(:job, :agent)&.downcase&.gsub(/[^a-z0-9-]/, "-")
              bot_token = Gateway.bot_token(agent_key) || Gateway.discord_bot_tokens.values.first
            end
            next unless bot_token

            snippet = ctx[:snippet]
            snippet_block = snippet ? "\n```\n#{snippet[-1500..]}\n```" : ""
            message = "💥 **#{ctx[:agent_name]} crashed** (exit code #{ctx[:exit_status]})\nLog: `#{ctx[:log_file]}`#{snippet_block}"

            Api.send_long_message(channel_id, message, token: bot_token, reply_to: source_context[:message_id])
            :discord
          end
        end

        def setup_routes(app)
          app.get "/api/discord" do
            content_type :json
            Brainiac::Plugins::Discord::Gateway.bots_status.to_json
          end

          app.get "/api/gif" do
            content_type :json
            query = params["q"]
            halt 400, { error: "missing q param" }.to_json unless query && !query.empty?

            results = Brainiac::Plugins::Discord::Api.search_gif(query)
            { results: results }.to_json
          end
        end
      end
    end
  end
end
