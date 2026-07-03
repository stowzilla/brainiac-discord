# frozen_string_literal: true

# Lightweight metadata for brainiac-discord.
# Loaded by `brainiac help` without pulling in the full plugin runtime.

require_relative "version"

module Brainiac
  module Plugins
    module Discord
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
        "    brainiac discord <command>    Manage Discord bots (config, token, status, map)"
      end
    end
  end
end
