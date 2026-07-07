# frozen_string_literal: true

require_relative "lib/brainiac/plugins/discord/version"

Gem::Specification.new do |s|
  s.name        = "brainiac-discord"
  s.version     = Brainiac::Plugins::Discord::VERSION
  s.summary     = "Discord bot plugin for Brainiac"
  s.description = "Full Discord integration for Brainiac — per-agent bot gateway connections, " \
                  "message handling, session supersede, draft delivery, reaction handlers " \
                  "(cancel, thinking peek, feedback logging), worktree management, " \
                  "and GIF support. Uses Brainiac's hook system for lifecycle integration."
  s.authors     = ["Andy Davis"]
  s.homepage    = "https://github.com/stowzilla/brainiac-discord"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.require_paths = ["lib"]

  s.add_dependency "brainiac", ">= 0.0.14"
  s.add_dependency "websocket-client-simple", "~> 0.8"

  s.add_development_dependency "minitest", "~> 5.25"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rubocop", "~> 1.75"
  s.add_development_dependency "rubocop-performance", "~> 1.25"

  s.metadata["rubygems_mfa_required"] = "true"
end
