# frozen_string_literal: true

require_relative "discord/version"
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
    end
  end
end
