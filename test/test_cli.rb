# frozen_string_literal: true

require_relative "test_helper"

class TestDiscordCli < Minitest::Test
  def setup
    # Save the original discord.json so CLI tests don't clobber it
    @config_file = Brainiac::Plugins::Discord::Cli::DISCORD_CONFIG_FILE
    @original_content = File.read(@config_file) if File.exist?(@config_file)
  end

  def teardown
    # Restore original config after each test
    File.write(@config_file, @original_content) if @original_content
    Brainiac::Plugins::Discord::Config.load!
  end

  def test_cli_method_exists
    assert_respond_to Brainiac::Plugins::Discord, :cli
  end

  def test_cli_module_run_exists
    assert_respond_to Brainiac::Plugins::Discord::Cli, :run
  end

  def test_cmd_config_no_file
    FileUtils.rm_f(@config_file)

    out = capture_io { Brainiac::Plugins::Discord::Cli.run(["config"]) }.first
    assert_includes out, "No Discord config found"
  end

  def test_cmd_config_with_file
    out = capture_io { Brainiac::Plugins::Discord::Cli.run(["config"]) }.first
    assert_includes out, "channel_mappings"
  end

  def test_cmd_default_sets_project
    Brainiac::Plugins::Discord::Cli.run(%w[default testproject])
    config = JSON.parse(File.read(@config_file))
    assert_equal "testproject", config["default_project"]
  end

  def test_cmd_map_sets_channel
    Brainiac::Plugins::Discord::Cli.run(%w[map ch-999 brainiac])
    config = JSON.parse(File.read(@config_file))
    assert_equal({ "project" => "brainiac" }, config["channel_mappings"]["ch-999"])
  end

  def test_cmd_owner_sets_id
    Brainiac::Plugins::Discord::Cli.run(%w[owner 123456789])
    config = JSON.parse(File.read(@config_file))
    assert_equal "123456789", config["owner_discord_id"]
  end

  def test_cmd_token_sets_bot_token
    registry_file = Brainiac::Plugins::Discord::Cli::AGENT_REGISTRY_FILE
    File.write(registry_file, JSON.generate({}))

    Brainiac::Plugins::Discord::Cli.run(%w[token testbot Bot_TEST123])
    registry = JSON.parse(File.read(registry_file))
    assert_equal "Bot_TEST123", registry.dig("testbot", "env", "DISCORD_BOT_TOKEN")
  ensure
    FileUtils.rm_f(registry_file)
  end

  def test_cmd_setup_shows_status
    out = capture_io { Brainiac::Plugins::Discord::Cli.run(["setup"]) }.first
    assert_includes out, "Discord Setup"
  end

  def test_cmd_help_shown_for_unknown
    out = capture_io { Brainiac::Plugins::Discord::Cli.run(["unknown-thing"]) }.first
    assert_includes out, "Usage: brainiac discord"
  end

  def test_cmd_help_shown_for_nil
    out = capture_io { Brainiac::Plugins::Discord::Cli.run([nil]) }.first
    assert_includes out, "Usage: brainiac discord"
  end
end
