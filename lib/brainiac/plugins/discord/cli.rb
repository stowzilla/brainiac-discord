# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Brainiac
  module Plugins
    module Discord
      # CLI subcommands for brainiac-discord plugin.
      #
      # Invoked when a user runs `brainiac discord <command>`.
      # Manages discord.json config and agent bot tokens.
      module Cli
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        DISCORD_CONFIG_FILE = File.join(BRAINIAC_DIR, "discord.json")
        AGENT_REGISTRY_FILE = File.join(BRAINIAC_DIR, "agents.json")

        class << self
          def run(args)
            command = args.shift

            case command
            when "config"
              cmd_config
            when "map"
              cmd_map(args)
            when "default"
              cmd_default(args)
            when "token"
              cmd_token(args)
            when "status"
              cmd_status
            when "owner"
              cmd_owner(args)
            when "setup"
              cmd_setup
            else
              print_help
            end
          end

          private

          def cmd_config
            if File.exist?(DISCORD_CONFIG_FILE)
              puts File.read(DISCORD_CONFIG_FILE)
            else
              puts "No Discord config found at #{DISCORD_CONFIG_FILE}"
              puts "Run 'brainiac discord setup' to configure Discord."
            end
          end

          def cmd_map(args)
            channel_id = args[0]
            project_key = args[1]

            unless channel_id && project_key
              puts "Usage: brainiac discord map <channel-id> <project-key>"
              exit 1
            end

            config = load_discord_config
            config["channel_mappings"] ||= {}
            config["channel_mappings"][channel_id] = { "project" => project_key }

            save_discord_config(config)
            puts "✓ Mapped channel #{channel_id} → project '#{project_key}'"
          end

          def cmd_default(args)
            project_key = args[0]

            unless project_key
              puts "Usage: brainiac discord default <project-key>"
              exit 1
            end

            config = load_discord_config
            config["default_project"] = project_key

            save_discord_config(config)
            puts "✓ Default project: #{project_key}"
          end

          def cmd_token(args)
            agent_key = args[0]
            token = args[1]

            unless agent_key && token
              puts "Usage: brainiac discord token <agent-key> <bot-token>"
              puts "  Sets the DISCORD_BOT_TOKEN env var for an agent in the registry."
              puts "  Example: brainiac discord token galen Bot_TOKEN_HERE"
              exit 1
            end

            registry = File.exist?(AGENT_REGISTRY_FILE) ? JSON.parse(File.read(AGENT_REGISTRY_FILE)) : {}
            registry[agent_key] ||= {}
            registry[agent_key]["env"] ||= {}
            registry[agent_key]["env"]["DISCORD_BOT_TOKEN"] = token

            FileUtils.mkdir_p(BRAINIAC_DIR)
            File.write(AGENT_REGISTRY_FILE, JSON.pretty_generate(registry))
            puts "✓ Set DISCORD_BOT_TOKEN for '#{agent_key}'"
          end

          def cmd_status
            server_url = detect_server_url
            begin
              uri = URI("#{server_url}/api/discord")
              response = Net::HTTP.get_response(uri)
              data = JSON.parse(response.body)
              if data["enabled"]
                bots = data["bots"] || {}
                if bots.empty?
                  puts "Discord: enabled but no bots configured"
                else
                  puts "Discord bots:"
                  bots.each do |agent, info|
                    puts "  #{agent}: #{info["status"]} (user_id: #{info["user_id"] || "n/a"})"
                  end
                end
                puts "Default project: #{data.dig("config", "default_project") || "none"}"
                puts "Channel mappings: #{data.dig("config", "channel_mappings")}"
              else
                puts "Discord: disabled (#{data["reason"]})"
              end
            rescue StandardError => e
              puts "Could not reach server at #{server_url}: #{e.message}"
              puts "Is the server running? Check with: brainiac status"
            end
          end

          def cmd_owner(args)
            discord_id = args[0]
            config = load_discord_config
            if discord_id
              config["owner_discord_id"] = discord_id
              save_discord_config(config)
              puts "✓ Owner set to #{discord_id}"
            elsif config["owner_discord_id"]
              puts "Owner: #{config["owner_discord_id"]}"
            else
              puts "No owner set."
              puts "Usage: brainiac discord owner <discord-user-id>"
            end
          end

          def cmd_setup
            puts "Discord Setup"
            puts "============="
            puts ""

            config = load_discord_config

            if config["default_project"]
              puts "✓ Default project: #{config["default_project"]}"
            else
              puts "⚠ No default project set."
              puts "  Set one with: brainiac discord default <project-key>"
            end
            puts ""

            registry = File.exist?(AGENT_REGISTRY_FILE) ? JSON.parse(File.read(AGENT_REGISTRY_FILE)) : {}
            agents_with_tokens = registry.select { |_k, v| v.is_a?(Hash) && v.dig("env", "DISCORD_BOT_TOKEN") }
            if agents_with_tokens.any?
              puts "✓ #{agents_with_tokens.size} agent(s) have Discord bot tokens:"
              agents_with_tokens.each do |key, entry|
                display = entry["display_name"] || key.capitalize
                puts "    #{display} (#{key})"
              end
            else
              puts "⚠ No agents have Discord bot tokens configured."
              puts "  Add one with: brainiac discord token <agent-key> <bot-token>"
              puts ""
              puts "  To get a bot token:"
              puts "  1. Go to https://discord.com/developers/applications"
              puts "  2. Create a new application (one per agent)"
              puts "  3. Go to Bot tab → Copy token"
              puts "  4. Enable MESSAGE CONTENT intent"
            end
            puts ""

            mappings = config["channel_mappings"] || {}
            if mappings.any?
              puts "✓ #{mappings.size} channel mapping(s) configured"
            else
              puts "  No channel mappings (using default project for all channels)"
              puts "  Optionally map specific channels: brainiac discord map <channel-id> <project>"
            end
            puts ""

            if agents_with_tokens.any? && config["default_project"]
              puts "✓ Discord is configured! Start with: brainiac server"
            else
              puts "Complete the steps above, then start with: brainiac server"
            end
          end

          def print_help
            puts <<~HELP
              Usage: brainiac discord <command>

              Commands:
                setup                               Interactive setup guide
                config                              Show Discord config
                default <project>                   Set default project for all channels
                map <channel-id> <project>          Map a specific channel to a project
                owner [<discord-user-id>]           Set/show machine owner (for version notifications)
                token <agent-key> <bot-token>       Set Discord bot token for an agent
                status                              Check Discord bot status (via server API)

              Each agent gets its own Discord bot. Users @mention @Galen or @GLaDOS
              directly in Discord — no shared bot needed.

              Quick start:
                brainiac discord token galen "BOT_TOKEN_FOR_GALEN"
                brainiac discord default marketplace
                brainiac server
            HELP
          end

          def load_discord_config
            if File.exist?(DISCORD_CONFIG_FILE)
              JSON.parse(File.read(DISCORD_CONFIG_FILE))
            else
              { "channel_mappings" => {}, "authorized_role_ids" => [], "authorized_user_ids" => [] }
            end
          rescue JSON::ParserError
            { "channel_mappings" => {}, "authorized_role_ids" => [], "authorized_user_ids" => [] }
          end

          def save_discord_config(config)
            FileUtils.mkdir_p(BRAINIAC_DIR)
            File.write(DISCORD_CONFIG_FILE, JSON.pretty_generate(config))
          end

          def detect_server_url
            config_file = File.join(BRAINIAC_DIR, "brainiac.json")
            if File.exist?(config_file)
              config = JSON.parse(File.read(config_file))
              config["server_url"] || "http://localhost:4567"
            else
              "http://localhost:4567"
            end
          rescue JSON::ParserError
            "http://localhost:4567"
          end
        end
      end

      # Plugin CLI entry point — called by brainiac core's plugin delegation.
      def self.cli(args)
        Cli.run(args)
      end

      # Subcommand names for bash completion.
      def self.completions
        %w[setup config default map owner token status]
      end
    end
  end
end
