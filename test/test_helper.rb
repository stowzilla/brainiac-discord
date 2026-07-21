# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "open3"

# --- Stub core constants and functions that the plugin expects ---

TEST_BRAINIAC_DIR = Dir.mktmpdir("brainiac-discord-test")

ENV["BRAINIAC_DIR"] = TEST_BRAINIAC_DIR

unless defined?(LOG)
  LOG = Class.new do
    def info(_msg) = nil
    def warn(_msg) = nil
    def error(_msg) = nil
    def debug(_msg) = nil
    def debug? = false
  end.new
end

AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)

# Stub core Brainiac module with hooks
module Brainiac
  @hooks = Hash.new { |h, k| h[k] = [] }
  @channel_prompts = {}
  @channel_pre_post_checks = {}

  class << self
    def on(event, &block) = @hooks[event] << block

    def emit(event, **ctx)
      @hooks[event].filter_map do |h|
        h.call(ctx)
      rescue StandardError
        nil
      end
    end

    def register_channel_prompt(channel, prompt, pre_post_check: nil)
      @channel_prompts[channel] = prompt
      @channel_pre_post_checks[channel] = pre_post_check if pre_post_check
    end
    attr_reader :hooks, :channel_prompts, :channel_pre_post_checks

    def reset_hooks!
      @hooks = Hash.new { |h, k| h[k] = [] }
      @channel_prompts = {}
      @channel_pre_post_checks = {}
    end
  end

  module Plugins; end
end

# Stub core constants
AGENT_REGISTRY = {
  "galen" => { "display_name" => "Galen", "local" => true,
               "env" => { "DISCORD_BOT_TOKEN" => "Bot_galen", "FIZZY_TOKEN" => "tok_galen" } },
  "glados" => { "display_name" => "GLaDOS", "local" => true,
                "env" => { "DISCORD_BOT_TOKEN" => "Bot_glados" } },
  "kaylee" => { "display_name" => "Kaylee", "local" => false, "env" => {} }
}.freeze

PROJECTS = {
  "marketplace" => { "repo_path" => "/tmp/test-repo", "tags" => %w[marketplace mp],
                     "github_repo" => "stowzilla/marketplace",
                     "allowed_models" => { "opus" => "claude-opus-4.6", "sonnet" => "claude-sonnet-4.6" } },
  "brainiac" => { "repo_path" => "/tmp/test-brainiac", "tags" => ["brainiac"],
                  "github_repo" => "stowzilla/brainiac" }
}.freeze

DEFAULT_PROJECT = {
  "agent_cli" => "kiro-cli",
  "agent_cli_args" => "chat --trust-all-tools --no-interactive",
  "agent_model_flag" => "--model",
  "allowed_models" => {}
}.freeze

# Session tracking stubs
ACTIVE_SESSIONS = {}
ACTIVE_SESSIONS_MUTEX = Mutex.new
SUPERSEDE_WINDOW = 60
AGENT_DISPATCH_DEPTH = {}

# Stub core functions
def agent_display_name(name)
  key = name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[key]
  return name unless entry.is_a?(Hash)

  entry["display_name"] || name
end

def agent_env_for(name)
  key = name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[key]
  return {} unless entry.is_a?(Hash)

  entry["env"] || {}
end

def reload_projects! = nil
def reload_agent_registry!(**) = nil
def record_human_comment(_key) = nil
def record_agent_dispatch(_key) = nil
def agent_dispatch_allowed?(_key) = true
def session_active?(_key) = false
def find_supersedable_session(_key) = nil
def kill_session(_key) = nil
def register_session(_key, _pid, **) = nil
def parse_inline_tags(text) = { project: nil, clean_text: text, chat_mode: false }
def detect_cli_provider(text: "", tags: []) = nil
def detect_model(_config, text: "") = nil
def detect_effort(_config, text: "") = nil

def resolve_work_item_overrides(work_item_id: nil, branch: nil, inline_cli_provider: nil, inline_model: nil, inline_effort: nil)
  { cli_provider: inline_cli_provider, model: inline_model, effort: inline_effort }
end

def resolve_project_cli_config(config, cli_provider_override: nil, agent_name: nil) = DEFAULT_PROJECT.merge(config || {})
def build_brain_context(agent_name:, card_title:, comment_body:) = ""
def render_prompt(_template, _vars, brain_context: "", agent_name: nil, channel: :discord) = "rendered prompt"
def render_discord_resume_prompt(message_body:, discord_user:, response_file:, agent_name:, card_id:) = "resume prompt"
def debounced_repo_fetch(_path) = nil
def get_default_branch(_path) = "main"
def create_or_reuse_worktree(repo_path:, branch:) = "/tmp/worktree-#{branch}"
def build_agent_cli_cmd(_resolved, _name, _model, _effort, _resume, _prompt_file) = %w[echo test]
def capture_git_state(_path) = [nil, nil]
def check_brainiac_restart(*) = nil
def notify_agent_crash(**) = nil
def brain_push(message:) = nil
def find_user_by_discord_id(_id) = nil
def persona_dir_for(name) = File.join(TEST_BRAINIAC_DIR, "brain", "persona", name.downcase)
def intent_config = { "enabled" => true }
def intent_skip?(_message, agent_name:, source: nil, channel: nil) = true
def check_intent(_message, agent_name:, channel:) = false

# Write discord.json for tests
discord_config = {
  "default_project" => "marketplace",
  "channel_mappings" => { "channel-brainiac" => { "project" => "brainiac" } },
  "authorized_role_ids" => [],
  "authorized_user_ids" => [],
  "user_mappings" => { "Andy" => "397928984232591361" },
  "giphy_api_key" => nil
}
File.write(File.join(TEST_BRAINIAC_DIR, "discord.json"), JSON.generate(discord_config))

# Create brain dirs
FileUtils.mkdir_p(File.join(TEST_BRAINIAC_DIR, "brain", "persona", "galen", "people"))
FileUtils.mkdir_p(File.join(TEST_BRAINIAC_DIR, "tmp", "discord", "draft"))
FileUtils.mkdir_p(File.join(TEST_BRAINIAC_DIR, "tmp", "discord", "posted"))

require_relative "../lib/brainiac_discord"

# Load config
Brainiac::Plugins::Discord::Config.load!

# Cleanup
Minitest.after_run { FileUtils.rm_rf(TEST_BRAINIAC_DIR) }
