# frozen_string_literal: true

require_relative "test_helper"

class TestDiscordPlugin < Minitest::Test
  def test_register_method_exists
    assert_respond_to Brainiac::Plugins::Discord, :register
  end

  def test_version_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Brainiac::Plugins::Discord::VERSION)
  end

  def test_configured_returns_boolean
    result = Brainiac::Plugins::Discord.configured?
    assert_includes [true, false], result
  end

  def test_help_text_defined
    text = Brainiac::Plugins::Discord.help_text
    assert_kind_of String, text
    assert_includes text, "brainiac discord"
  end

  def test_cli_method_exists
    assert_respond_to Brainiac::Plugins::Discord, :cli
  end

  def test_prompts_channel_defined
    assert_kind_of String, Brainiac::Plugins::Discord::Prompts::CHANNEL
    assert_includes Brainiac::Plugins::Discord::Prompts::CHANNEL, "Discord"
  end

  def test_prompts_situation_defined
    assert_kind_of String, Brainiac::Plugins::Discord::Prompts::SITUATION
    assert_includes Brainiac::Plugins::Discord::Prompts::SITUATION, "DISCORD_USER"
    assert_includes Brainiac::Plugins::Discord::Prompts::SITUATION, "RESPONSE_FILE"
  end

  def test_prompts_channel_includes_gif_section
    assert_includes Brainiac::Plugins::Discord::Prompts::CHANNEL, "GIF"
  end

  def test_prompts_channel_includes_thread_memory
    assert_includes Brainiac::Plugins::Discord::Prompts::CHANNEL, "Thread Memory"
  end
end

class TestDiscordConfig < Minitest::Test
  def test_load_config
    config = Brainiac::Plugins::Discord::Config.current
    assert_equal "marketplace", config["default_project"]
  end

  def test_default_project
    assert_equal "marketplace", Brainiac::Plugins::Discord::Config.default_project
  end

  def test_channel_mappings
    mappings = Brainiac::Plugins::Discord::Config.channel_mappings
    assert_kind_of Hash, mappings
    assert mappings.key?("channel-brainiac")
  end

  def test_user_mappings
    mappings = Brainiac::Plugins::Discord::Config.user_mappings
    assert_equal "397928984232591361", mappings["Andy"]
  end

  def test_authorized_user_ids_empty
    assert_empty Brainiac::Plugins::Discord::Config.authorized_user_ids
  end

  def test_authorized_role_ids_empty
    assert_empty Brainiac::Plugins::Discord::Config.authorized_role_ids
  end

  def test_find_project_for_mapped_channel
    result = Brainiac::Plugins::Discord::Config.find_project_for_channel("channel-brainiac")
    assert result
    project_key, _config, _mapping = result
    assert_equal "brainiac", project_key
  end

  def test_find_project_for_unmapped_uses_default
    result = Brainiac::Plugins::Discord::Config.find_project_for_channel("random-channel-999")
    assert result
    project_key, _config, _mapping = result
    assert_equal "marketplace", project_key
  end

  def test_find_project_nil_without_default
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, { "channel_mappings" => {} })
    assert_nil Brainiac::Plugins::Discord::Config.find_project_for_channel("unknown")
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end

  def test_thread_map_persistence
    thread_map_file = Brainiac::Plugins::Discord::Config::DISCORD_THREAD_MAP_FILE
    FileUtils.rm_f(thread_map_file)
    assert_equal({}, Brainiac::Plugins::Discord::Config.load_thread_map)

    map = { "galen:ch1" => { "worktree" => "/tmp/wt" } }
    Brainiac::Plugins::Discord::Config.save_thread_map(map)
    loaded = Brainiac::Plugins::Discord::Config.load_thread_map
    assert_equal "/tmp/wt", loaded["galen:ch1"]["worktree"]
  ensure
    FileUtils.rm_f(thread_map_file)
  end

  def test_reload
    Brainiac::Plugins::Discord::Config.reload!
    assert_equal "marketplace", Brainiac::Plugins::Discord::Config.default_project
  end
end

class TestDiscordGateway < Minitest::Test
  def test_discord_bot_tokens_collected
    tokens = Brainiac::Plugins::Discord::Gateway.discord_bot_tokens
    assert_equal "Bot_galen", tokens["galen"]
    assert_equal "Bot_glados", tokens["glados"]
  end

  def test_discord_bot_tokens_excludes_agents_without_token
    tokens = Brainiac::Plugins::Discord::Gateway.discord_bot_tokens
    refute tokens.key?("kaylee")
  end

  def test_bots_status_empty_before_start
    status = Brainiac::Plugins::Discord::Gateway.bots_status
    assert_kind_of Hash, status
  end

  def test_bot_count
    assert_kind_of Integer, Brainiac::Plugins::Discord::Gateway.bot_count
  end

  def test_detect_sender_agent_unknown
    author = { "id" => "unknown-id-999", "username" => "randoBot" }
    result = Brainiac::Plugins::Discord::Gateway.detect_sender_agent(author, "galen")
    assert_nil result
  end

  def test_detect_sender_agent_from_user_mappings
    author = { "id" => "397928984232591361", "username" => "Andy" }
    result = Brainiac::Plugins::Discord::Gateway.detect_sender_agent(author, "galen")
    assert_equal "andy", result
  end
end

class TestDiscordApi < Minitest::Test
  def test_reserved_emojis_defined
    assert_includes Brainiac::Plugins::Discord::Api::RESERVED_EMOJIS, "👀"
    assert_includes Brainiac::Plugins::Discord::Api::RESERVED_EMOJIS, "❌"
    assert_includes Brainiac::Plugins::Discord::Api::RESERVED_EMOJIS, "🧠"
  end

  def test_mention_roster_includes_user_mappings
    roster = Brainiac::Plugins::Discord::Api.mention_roster
    assert_includes roster, "Andy"
    assert_includes roster, "397928984232591361"
  end
end

class TestDiscordDelivery < Minitest::Test
  def setup
    @draft_dir = Brainiac::Plugins::Discord::Delivery::DRAFT_DIR
    @posted_dir = Brainiac::Plugins::Discord::Delivery::POSTED_DIR
    FileUtils.mkdir_p(@draft_dir)
    FileUtils.mkdir_p(@posted_dir)
  end

  def test_deliver_draft_returns_false_without_meta
    refute Brainiac::Plugins::Discord::Delivery.deliver_draft("/nonexistent.md", "/nonexistent.meta.json")
  end

  def test_deliver_draft_returns_false_without_response_file
    meta_file = File.join(@draft_dir, "test.meta.json")
    File.write(meta_file, JSON.generate({
                                          "agent_key" => "galen", "agent_name" => "Galen",
                                          "channel_id" => "ch1", "message_id" => "msg1"
                                        }))
    refute Brainiac::Plugins::Discord::Delivery.deliver_draft("/nonexistent-response.md", meta_file)
  ensure
    FileUtils.rm_f(meta_file)
    FileUtils.rm_f("#{meta_file}.lock")
  end

  def test_draft_and_posted_dirs_exist
    assert Dir.exist?(@draft_dir)
    assert Dir.exist?(@posted_dir)
  end
end

class TestDiscordReactions < Minitest::Test
  def test_reactions_module_exists
    assert_respond_to Brainiac::Plugins::Discord::Reactions, :handle
  end
end

class TestDiscordMessage < Minitest::Test
  def test_message_module_exists
    assert_respond_to Brainiac::Plugins::Discord::Message, :handle
  end
end
