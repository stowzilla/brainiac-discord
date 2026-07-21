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

class TestDiscordPersistOverrides < Minitest::Test
  def setup
    @thread_map_file = Brainiac::Plugins::Discord::Config::DISCORD_THREAD_MAP_FILE
    FileUtils.rm_f(@thread_map_file)
    # Override detect_cli_provider to actually parse [cli:X] tags for these tests
    @original_detect_cli = method(:detect_cli_provider)
  end

  def teardown
    FileUtils.rm_f(@thread_map_file)
  end

  def test_persist_overrides_updates_thread_map_cli_provider
    map = { "galen:thread123" => { "worktree" => "/tmp/wt", "cli_provider" => "grok", "model" => nil, "effort" => nil } }
    Brainiac::Plugins::Discord::Config.save_thread_map(map)

    # Temporarily make detect_cli_provider work for real
    Object.define_method(:detect_cli_provider) { |text: "", tags: []| (m = text.match(/\[cli:(\w+)\]/i)) ? m[1].downcase : nil }

    Brainiac::Plugins::Discord::Message.send(
      :persist_overrides, "galen:thread123", "[cli:kiro] hello", nil,
      cli_provider: "kiro", model: nil, effort: nil,
      prev_cli_provider: "grok", prev_model: nil, prev_effort: nil
    )

    updated = Brainiac::Plugins::Discord::Config.load_thread_map
    assert_equal "kiro", updated["galen:thread123"]["cli_provider"]
  ensure
    Object.define_method(:detect_cli_provider) { |text: "", tags: []| nil }
  end

  def test_persist_overrides_updates_thread_map_model
    map = { "galen:thread456" => { "worktree" => "/tmp/wt", "cli_provider" => nil, "model" => nil, "effort" => nil } }
    Brainiac::Plugins::Discord::Config.save_thread_map(map)

    project_config = { "allowed_models" => { "opus" => "claude-opus-4.6" } }

    Brainiac::Plugins::Discord::Message.send(
      :persist_overrides, "galen:thread456", "[opus] do something", project_config,
      cli_provider: nil, model: "claude-opus-4.6", effort: nil,
      prev_cli_provider: nil, prev_model: nil, prev_effort: nil
    )

    updated = Brainiac::Plugins::Discord::Config.load_thread_map
    assert_equal "claude-opus-4.6", updated["galen:thread456"]["model"]
  end

  def test_persist_overrides_noop_when_no_inline_tags
    map = { "galen:thread789" => { "worktree" => "/tmp/wt", "cli_provider" => "grok", "model" => nil, "effort" => nil } }
    Brainiac::Plugins::Discord::Config.save_thread_map(map)

    Brainiac::Plugins::Discord::Message.send(
      :persist_overrides, "galen:thread789", "just a normal message", nil,
      cli_provider: "grok", model: nil, effort: nil,
      prev_cli_provider: "grok", prev_model: nil, prev_effort: nil
    )

    updated = Brainiac::Plugins::Discord::Config.load_thread_map
    assert_equal "grok", updated["galen:thread789"]["cli_provider"]
  end

  def test_persist_overrides_noop_when_no_thread_map_key
    Brainiac::Plugins::Discord::Message.send(
      :persist_overrides, nil, "[cli:kiro] hello", nil,
      cli_provider: "kiro", model: nil, effort: nil,
      prev_cli_provider: "grok", prev_model: nil, prev_effort: nil
    )

    refute File.exist?(@thread_map_file)
  end

  def test_persist_overrides_updates_effort
    map = { "galen:threadE" => { "worktree" => "/tmp/wt", "cli_provider" => nil, "model" => nil, "effort" => nil } }
    Brainiac::Plugins::Discord::Config.save_thread_map(map)

    Brainiac::Plugins::Discord::Message.send(
      :persist_overrides, "galen:threadE", "[effort:high] build this", nil,
      cli_provider: nil, model: nil, effort: "high",
      prev_cli_provider: nil, prev_model: nil, prev_effort: nil
    )

    updated = Brainiac::Plugins::Discord::Config.load_thread_map
    assert_equal "high", updated["galen:threadE"]["effort"]
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

  def test_start_bot_adds_to_bots_hash
    Brainiac::Plugins::Discord::Gateway.start_bot!("testbot", "Bot_test123")
    status = Brainiac::Plugins::Discord::Gateway.bots_status
    assert status.key?("testbot")
    assert_equal "starting", status["testbot"][:status]
  ensure
    Brainiac::Plugins::Discord::Gateway.stop_bot!("testbot")
  end

  def test_start_bot_noop_if_already_running
    Brainiac::Plugins::Discord::Gateway.start_bot!("testbot2", "Bot_test456")
    Brainiac::Plugins::Discord::Gateway.start_bot!("testbot2", "Bot_different")
    status = Brainiac::Plugins::Discord::Gateway.bots_status
    assert status.key?("testbot2")
  ensure
    Brainiac::Plugins::Discord::Gateway.stop_bot!("testbot2")
  end

  def test_stop_bot_removes_from_bots_hash
    Brainiac::Plugins::Discord::Gateway.start_bot!("testbot3", "Bot_test789")
    Brainiac::Plugins::Discord::Gateway.stop_bot!("testbot3")
    status = Brainiac::Plugins::Discord::Gateway.bots_status
    refute status.key?("testbot3")
  end

  def test_stop_bot_noop_for_unknown_agent
    Brainiac::Plugins::Discord::Gateway.stop_bot!("nonexistent-agent")
    # Should not raise
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

  def test_thread_participant_returns_true_when_bot_was_mentioned
    messages = [
      { "content" => "Hey <@123456> check this out", "mentions" => [{ "id" => "123456" }], "author" => { "id" => "999" } },
      { "content" => "Some other message", "mentions" => [], "author" => { "id" => "888" } }
    ]

    Brainiac::Plugins::Discord::Api.stub(:request, messages) do
      result = Brainiac::Plugins::Discord::Message.send(:thread_participant?, "ch1", "msg99", "123456", "token")
      assert result, "Should detect bot as thread participant when mentioned in history"
    end
  end

  def test_thread_participant_returns_true_when_bot_posted
    messages = [
      { "content" => "I posted this", "mentions" => [], "author" => { "id" => "123456" } },
      { "content" => "Some other message", "mentions" => [], "author" => { "id" => "888" } }
    ]

    Brainiac::Plugins::Discord::Api.stub(:request, messages) do
      result = Brainiac::Plugins::Discord::Message.send(:thread_participant?, "ch1", "msg99", "123456", "token")
      assert result, "Should detect bot as thread participant when it posted previously"
    end
  end

  def test_thread_participant_returns_false_when_bot_not_in_history
    messages = [
      { "content" => "Hello world", "mentions" => [], "author" => { "id" => "999" } },
      { "content" => "Some other message", "mentions" => [], "author" => { "id" => "888" } }
    ]

    Brainiac::Plugins::Discord::Api.stub(:request, messages) do
      result = Brainiac::Plugins::Discord::Message.send(:thread_participant?, "ch1", "msg99", "123456", "token")
      refute result, "Should not detect bot as participant when absent from history"
    end
  end

  def test_thread_participant_returns_false_on_api_error
    Brainiac::Plugins::Discord::Api.stub(:request, nil) do
      result = Brainiac::Plugins::Discord::Message.send(:thread_participant?, "ch1", "msg99", "123456", "token")
      refute result, "Should return false when API returns nil"
    end
  end

  def test_role_mentioned_detects_role_id_from_mention_roles
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    new_config = original_config.merge("role_mappings" => { "Galen" => "111222333" })
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, new_config)

    message = { "mention_roles" => ["111222333"] }
    result = Brainiac::Plugins::Discord::Message.send(:role_mentioned?, message, "test content", "galen")
    assert result, "Should detect role mention from mention_roles array"
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end

  def test_role_mentioned_detects_role_id_from_content
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    new_config = original_config.merge("role_mappings" => { "Galen" => "111222333" })
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, new_config)

    message = { "mention_roles" => [] }
    result = Brainiac::Plugins::Discord::Message.send(:role_mentioned?, message, "Hey <@&111222333> fix this", "galen")
    assert result, "Should detect role mention from content pattern"
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end

  def test_role_mentioned_returns_false_without_role_config
    message = { "mention_roles" => ["111222333"] }
    result = Brainiac::Plugins::Discord::Message.send(:role_mentioned?, message, "test", "galen")
    refute result, "Should return false when agent has no role_id configured"
  end

  def test_solo_in_thread_returns_true_when_no_other_bots_posted
    history = "Andy: hello\nGalen: galen response"

    bots = { "galen" => { user_id: "222", username: "Galen" }, "effie" => { user_id: "333", username: "Effie" } }
    original_bots = Brainiac::Plugins::Discord::Gateway.instance_variable_get(:@bots)
    Brainiac::Plugins::Discord::Gateway.instance_variable_set(:@bots, bots)
    result = Brainiac::Plugins::Discord::Message.send(:solo_in_thread?, history, "galen")
    assert result, "Should return true when only this bot posted (no other agents in thread)"
  ensure
    Brainiac::Plugins::Discord::Gateway.instance_variable_set(:@bots, original_bots)
  end

  def test_solo_in_thread_returns_false_when_other_bot_posted
    history = "Andy: hello\nGalen: galen response\nEffie: effie response"

    bots = { "galen" => { user_id: "222", username: "Galen" }, "effie" => { user_id: "333", username: "Effie" } }
    original_bots = Brainiac::Plugins::Discord::Gateway.instance_variable_get(:@bots)
    Brainiac::Plugins::Discord::Gateway.instance_variable_set(:@bots, bots)
    result = Brainiac::Plugins::Discord::Message.send(:solo_in_thread?, history, "galen")
    refute result, "Should return false when another agent bot posted in thread"
  ensure
    Brainiac::Plugins::Discord::Gateway.instance_variable_set(:@bots, original_bots)
  end

  def test_solo_in_thread_returns_true_with_empty_history
    result = Brainiac::Plugins::Discord::Message.send(:solo_in_thread?, "", "galen")
    assert result, "Should return true with empty history (assume solo)"
  end

  def test_solo_in_thread_returns_true_with_nil_history
    result = Brainiac::Plugins::Discord::Message.send(:solo_in_thread?, nil, "galen")
    assert result, "Should return true with nil history (assume solo)"
  end
end

class TestOtherAgentMentioned < Minitest::Test
  def setup
    @original_bots = Brainiac::Plugins::Discord::Gateway.instance_variable_get(:@bots).dup
    Brainiac::Plugins::Discord::Gateway.instance_variable_get(:@bots).merge!(
      "galen" => { user_id: "1475925968584573181", token: "t1", status: "ready" },
      "effie" => { user_id: "1520149980399272027", token: "t2", status: "ready" }
    )
  end

  def teardown
    Brainiac::Plugins::Discord::Gateway.instance_variable_set(:@bots, @original_bots)
  end

  def test_returns_true_when_another_bot_mentioned_in_mentions_array
    mentions = [{ "id" => "1475925968584573181" }]
    content = "<@1475925968584573181> fix this"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    assert result, "Effie should detect that Galen is mentioned"
  end

  def test_returns_true_when_another_bot_mentioned_in_content
    mentions = []
    content = "Hey <@1475925968584573181> fix this"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    assert result, "Effie should detect Galen mention in content"
  end

  def test_returns_false_when_no_other_bot_mentioned
    mentions = []
    content = "Hey everyone, what's up?"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    refute result, "Should return false when no bot is mentioned"
  end

  def test_returns_false_when_only_self_mentioned
    mentions = [{ "id" => "1520149980399272027" }]
    content = "<@1520149980399272027> do something"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    refute result, "Should not count self-mention as 'other agent mentioned'"
  end

  def test_returns_true_with_role_mention_of_another_agent
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    new_config = original_config.merge("role_mappings" => { "Galen" => "1475937735545061521" })
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, new_config)

    mentions = []
    content = "Hey <@&1475937735545061521> fix this"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    assert result, "Effie should detect Galen's role mention"
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end

  def test_returns_true_when_human_user_mentioned_in_mentions_array
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    new_config = original_config.merge("user_mappings" => { "Andy" => "397928984232591361" })
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, new_config)

    mentions = [{ "id" => "397928984232591361" }]
    content = "<@397928984232591361> hey what do you think?"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    assert result, "Effie should detect that a mapped human user (Andy) is mentioned"
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end

  def test_returns_true_when_human_user_mentioned_in_content_only
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    new_config = original_config.merge("user_mappings" => { "Adam" => "832331260088287242" })
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, new_config)

    mentions = []
    content = "<@832331260088287242> Ughhhh, they said skip but Effie activated anyway?!"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    assert result, "Effie should detect Adam's mention in content and stand down"
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end

  def test_returns_false_when_unmapped_user_mentioned
    original_config = Brainiac::Plugins::Discord::Config.current.dup
    new_config = original_config.merge("user_mappings" => { "Andy" => "397928984232591361" })
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, new_config)

    mentions = [{ "id" => "999999999999999999" }]
    content = "<@999999999999999999> hey unmapped person"
    result = Brainiac::Plugins::Discord::Message.send(:other_agent_mentioned?, mentions, content, "effie")
    refute result, "Should not stand down for unmapped user mentions"
  ensure
    Brainiac::Plugins::Discord::Config.instance_variable_set(:@config, original_config)
  end
end
