# frozen_string_literal: true

module Brainiac
  module Plugins
    module Discord
      # Discord configuration — loads ~/.brainiac/discord.json.
      # Provides channel mappings, authorization, user mappings, and project routing.
      module Config
        DISCORD_CONFIG_FILE = File.join(
          ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
          "discord.json"
        )

        DISCORD_THREAD_MAP_FILE = File.join(
          ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
          "discord_thread_map.json"
        )

        @config = {}
        @thread_map_mutex = Mutex.new

        class << self
          attr_reader :config, :thread_map_mutex

          def load!
            @config = if File.exist?(DISCORD_CONFIG_FILE)
                        JSON.parse(File.read(DISCORD_CONFIG_FILE))
                      else
                        { "channel_mappings" => {}, "authorized_role_ids" => [], "authorized_user_ids" => [] }
                      end
          rescue JSON::ParserError => e
            LOG.error "[Discord] Failed to parse discord.json: #{e.message}" if defined?(LOG)
            @config = { "channel_mappings" => {}, "authorized_role_ids" => [], "authorized_user_ids" => [] }
          end

          def reload!
            load!
          end

          def current
            @config
          end

          def default_project
            @config["default_project"]
          end

          def owner_discord_id
            @config["owner_discord_id"]
          end

          def dashboard_token
            @config["dashboard_token"]
          end

          def giphy_api_key
            @config["giphy_api_key"]
          end

          def channel_mappings
            @config["channel_mappings"] || {}
          end

          def user_mappings
            @config["user_mappings"] || {}
          end

          def authorized_role_ids
            if @config["role_mappings"]
              @config["role_mappings"].values
            elsif @config["authorized_role_ids"].is_a?(Hash)
              @config["authorized_role_ids"].values
            else
              @config["authorized_role_ids"] || []
            end.map(&:to_s)
          end

          def authorized_user_ids
            @config["authorized_user_ids"] || []
          end

          # Find the project for a given Discord channel.
          # Returns [project_key, project_config, mapping] or nil.
          def find_project_for_channel(channel_id)
            mapping = channel_mappings[channel_id]

            unless mapping
              default = default_project
              mapping = { "project" => default } if default
            end

            return nil unless mapping

            project_key = mapping["project"]
            project_config = PROJECTS[project_key]
            return nil unless project_config

            [project_key, project_config, mapping]
          end

          # --- Thread Map Persistence ---

          def load_thread_map
            return {} unless File.exist?(DISCORD_THREAD_MAP_FILE)

            JSON.parse(File.read(DISCORD_THREAD_MAP_FILE))
          rescue JSON::ParserError
            {}
          end

          def save_thread_map(map)
            File.write(DISCORD_THREAD_MAP_FILE, JSON.pretty_generate(map))
          end
        end
      end
    end
  end
end
