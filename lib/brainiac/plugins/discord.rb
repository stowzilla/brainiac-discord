# frozen_string_literal: true

require_relative "discord/version"
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

          # Start all per-agent Discord bot gateway connections
          Brainiac::Plugins::Discord::Gateway.start_all!

          # Start draft delivery poller
          Brainiac::Plugins::Discord::Delivery.start_poller!

          # Set up API routes
          setup_routes(app)

          LOG.info "[Discord] Plugin registered (#{Brainiac::Plugins::Discord::Gateway.bot_count} bots)"
        end

        private

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

      # Returns true if Discord has at least one bot token configured.
      def self.configured?
        registry_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "agents.json")
        return false unless File.exist?(registry_file)

        registry = JSON.parse(File.read(registry_file))
        registry.any? { |_k, v| v.is_a?(Hash) && v.dig("env", "DISCORD_BOT_TOKEN") }
      rescue StandardError
        false
      end

      # Help text shown in `brainiac help` when the plugin is installed.
      def self.help_text
        <<~HELP.chomp
          brainiac discord <command>    Manage Discord bots (config, token, status, map)
        HELP
      end
    end
  end
end
