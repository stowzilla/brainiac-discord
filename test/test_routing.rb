# frozen_string_literal: true

require_relative "test_helper"

# Multi-machine: the leader hands Discord work to the machine that should run it.
class TestDiscordRouting < Minitest::Test
  Discord = Brainiac::Plugins::Discord
  Routing = Discord::Routing

  # Stands in for core's Brainiac::Hub.
  module FakeHub
    class << self
      attr_accessor :enabled, :owners, :nodes, :relay_result, :calls

      def enabled? = enabled
      def machine_name = "main"
      def owner(key) = (calls << [:owner, key]) && owners[key]
      def status = nodes && { "nodes" => nodes }
      def assign(keys, machine, overwrite: true) = calls << [:assign, keys, machine, overwrite]
      def release(key) = calls << [:release, key]

      def relay(**args)
        calls << [:relay, args]
        relay_result == :echo ? { "status" => "delivered", "machine" => args[:machine] || owners[args[:keys].first] } : relay_result
      end

      def relays = calls.select { |call| call.first == :relay }.map(&:last)
    end
  end

  def setup
    Brainiac.send(:remove_const, :Hub) if Brainiac.const_defined?(:Hub, false)
    Brainiac.const_set(:Hub, FakeHub)
    FakeHub.enabled = true
    FakeHub.owners = {}
    FakeHub.calls = []
    FakeHub.relay_result = :echo
    FakeHub.nodes = [{ "name" => "main", "online" => true }, { "name" => "mini", "online" => true },
                     { "name" => "gpu", "online" => false }]
    Routing.reset!
    @in_background = Routing.method(:in_background)
    Routing.define_singleton_method(:in_background) { |&block| block.call }
    @said = []
  end

  def teardown
    Brainiac.send(:remove_const, :Hub) if Brainiac.const_defined?(:Hub, false)
    Routing.define_singleton_method(:in_background, @in_background)
    Routing.singleton_class.send(:private, :in_background)
    Routing.reset!
  end

  # Runs Message.accept far enough to see the routing decision, then stops at
  # the attachment download (the first thing a machine does once work is its own).
  def accept(content, relayed: false)
    handed = []
    message = { "id" => "msg1", "channel_id" => "chan1", "content" => content,
                "author" => { "id" => "397928984232591361", "username" => "andy" } }
    hand = lambda do |**args|
      handed << args
      true
    end
    # Parse only the [machine:x] tag for these tests
    Object.define_method(:parse_inline_tags) { |text| { machine: text[/\[machine:(\w+)\]/, 1], clean_text: text } }

    Discord::Api.stub(:fetch_channel_info, { "type" => 0 }) do
      Discord::Message.stub(:download_attachments, ->(*) { throw :ran_here }) do
        Routing.stub(:hand_off_message, hand) do
          catch(:ran_here) do
            Discord::Message.accept(message, "galen", "Bot_galen", "111", mentioned: true, is_reply_to_bot: false,
                                                                          in_own_thread: false, relayed: relayed)
            return [handed, :stopped]
          end
        end
      end
    end
    [handed, :ran_here]
  ensure
    Object.define_method(:parse_inline_tags) { |text| { project: nil, clean_text: text, chat_mode: false } }
  end

  def test_message_is_routed_before_any_local_work
    handed, outcome = accept("<@111> [machine:mini] fix the thing")

    assert_equal :stopped, outcome
    assert_equal "mini", handed.first[:requested]
    assert_equal :channel, handed.first[:place]
    assert handed.first[:verdict]["mentioned"]
  end

  def test_relayed_message_is_never_routed_again
    handed, outcome = accept("<@111> [machine:gpu] fix the thing", relayed: true)

    assert_empty handed, "a machine that receives handed-over work must run it, not pass it on"
    assert_equal :ran_here, outcome
  end

  def hand_off(place: :channel, requested: nil, channel_id: "chan1", message_id: "msg1")
    said = @said
    Discord::Api.stub(:send_message, ->(_channel, text, **) { said << text }) do
      Routing.hand_off_message(
        agent_key: "galen", bot_token: "Bot_galen", bot_user_id: "111", requested: requested, place: place,
        message: { "id" => message_id, "channel_id" => channel_id, "content" => "hi" }, verdict: { "mentioned" => true }
      )
    end
  end

  def test_does_nothing_without_a_hub
    FakeHub.enabled = false

    refute hand_off(place: :thread, requested: "mini")
    assert_nil Routing.machine
    assert_empty FakeHub.calls
  end

  def test_untagged_channel_message_runs_here_without_asking_the_hub
    refute hand_off
    refute hand_off(place: :dm)
    assert_empty FakeHub.calls
  end

  def test_tagged_channel_message_goes_to_that_machine_keyed_by_its_future_thread
    assert hand_off(requested: "mini")

    relay = FakeHub.relays.last
    assert_equal "/hub/discord/message", relay[:path]
    assert_equal "mini", relay[:machine]
    assert_equal ["discord:galen:msg1"], relay[:keys]
    refute relay[:reassign]
    assert_equal "galen", relay[:payload]["agent_key"]
    assert_equal "111", relay[:payload]["bot_user_id"]
    assert_equal({ "mentioned" => true }, relay[:payload]["verdict"])
    refute relay[:payload].to_s.include?("Bot_galen"), "a bot token must never travel through the hub"
    assert_empty @said
  end

  def test_thread_follows_its_owner
    FakeHub.owners["discord:galen:thread1"] = "mini"

    assert hand_off(place: :thread, channel_id: "thread1")

    relay = FakeHub.relays.last
    assert_nil relay[:machine]
    assert_equal ["discord:galen:thread1"], relay[:keys]
    refute relay[:reassign]
  end

  def test_thread_owned_here_or_by_nobody_runs_here
    refute hand_off(place: :thread, channel_id: "thread1")
    FakeHub.owners["discord:galen:thread1"] = "main"
    refute hand_off(place: :thread, channel_id: "thread1")
    assert_empty FakeHub.relays
  end

  def test_tag_in_a_thread_moves_it
    FakeHub.owners["discord:galen:thread1"] = "main"

    assert hand_off(place: :thread, channel_id: "thread1", requested: "mini")

    relay = FakeHub.relays.last
    assert_equal "mini", relay[:machine]
    assert relay[:reassign]
  end

  def test_tag_naming_this_machine_takes_the_thread_back
    FakeHub.owners["discord:galen:thread1"] = "mini"

    refute hand_off(place: :thread, channel_id: "thread1", requested: "main")

    assert_empty FakeHub.relays
    assert_includes FakeHub.calls, [:assign, ["discord:galen:thread1"], "main", true]
  end

  def test_unknown_machine_is_refused_with_a_note
    assert hand_off(requested: "minni")

    assert_empty FakeHub.relays
    assert_match(/No machine named `minni`.*`main`, `mini`, `gpu`/, @said.last)
  end

  def test_offline_machine_does_not_pull_a_thread_off_its_owner
    FakeHub.owners["discord:galen:thread1"] = "mini"

    assert hand_off(place: :thread, channel_id: "thread1", requested: "gpu")

    relay = FakeHub.relays.last
    assert_nil relay[:machine]
    refute relay[:reassign]
    assert_match(/`gpu` is offline, so this thread stays on `mini`/, @said.first)
  end

  def test_offline_machine_for_new_work_reports_the_fallback
    FakeHub.relay_result = { "status" => "delivered", "machine" => "mini" }

    assert hand_off(requested: "gpu")

    assert_equal "gpu", FakeHub.relays.last[:machine]
    assert_match(/`gpu` did not answer. Running on `mini`/, @said.last)
  end

  def test_queued_and_unreachable_hub_are_reported
    FakeHub.owners["discord:galen:thread1"] = "mini"
    FakeHub.relay_result = { "status" => "queued", "machine" => "mini" }
    assert hand_off(place: :thread, channel_id: "thread1")
    assert_match(/`mini` is offline. This is queued/, @said.last)

    FakeHub.relay_result = nil
    assert hand_off(place: :thread, channel_id: "thread1"), "work owned elsewhere must not quietly run here"
    assert_match(/Could not reach the hub.*nothing ran/, @said.last)
  end

  def test_session_reactions_follow_a_handed_off_message
    reaction = { "channel_id" => "chan1", "message_id" => "msg1", "user_id" => "9", "emoji" => { "name" => "❌" } }
    refute Routing.hand_off_reaction(agent_key: "galen", bot_user_id: "111", reaction: reaction)

    hand_off(requested: "mini")
    assert Routing.hand_off_reaction(agent_key: "galen", bot_user_id: "111", reaction: reaction)
    refute Routing.hand_off_reaction(agent_key: "glados", bot_user_id: "222", reaction: reaction)

    relay = FakeHub.relays.last
    assert_equal "/hub/discord/reaction", relay[:path]
    assert_equal "mini", relay[:machine]
    assert_equal reaction, relay[:payload]["reaction"]
  end

  def test_archive_of_a_thread_owned_elsewhere_is_passed_on
    refute Routing.hand_off_archive(agent_key: "galen", data: { "id" => "thread1" })

    FakeHub.owners["discord:galen:thread1"] = "mini"
    assert Routing.hand_off_archive(agent_key: "galen", data: { "id" => "thread1" })
    assert_equal "/hub/discord/thread-archive", FakeHub.relays.last[:path]
    assert_equal ["discord:galen:thread1"], FakeHub.relays.last[:keys]
  end

  def test_claim_is_sent_once
    Routing.claim_thread("galen", "thread1")
    Routing.claim_thread("galen", "thread1")
    assert_equal [[:assign, ["discord:galen:thread1"], "main", false]], FakeHub.calls
  end

  # Everything after the routing decision, on a machine with no hub: the path
  # every message takes on a single machine.
  def test_accept_without_a_hub_reaches_dispatch
    FakeHub.enabled = false
    dispatched = nil
    message = { "id" => "msg1", "channel_id" => "chan1", "content" => "<@111> fix the thing",
                "author" => { "id" => "397928984232591361", "username" => "andy" } }

    Discord::Api.stub(:fetch_channel_info, { "type" => 0 }) do
      Discord::Api.stub(:fetch_channel_history, "andy: earlier") do
        Discord::Message.stub(:route_dispatch, ->(**args) { dispatched = args }) do
          Discord::Message.accept(message, "galen", "Bot_galen", "111", mentioned: true, is_reply_to_bot: false,
                                                                        in_own_thread: false)
        end
      end
    end

    assert_equal "fix the thing", dispatched[:clean_content]
    assert_equal "andy", dispatched[:discord_user]
    assert_equal "chan1", dispatched[:parent_channel_id]
    assert dispatched[:directly_addressed]
    refute dispatched[:is_thread]
    assert_empty FakeHub.calls
  end

  def test_moved_thread_starts_from_the_branch_the_old_machine_pushed
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", dir)
      system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "--allow-empty", "-m", "x")
      system("git", "-C", dir, "update-ref", "refs/remotes/origin/discord-galen-12345678", "HEAD")

      base = Discord::Message.send(:moved_thread_base, dir, "discord-galen-12345678")
      assert_equal({ base_ref: "origin/discord-galen-12345678" }, base)
      assert_empty Discord::Message.send(:moved_thread_base, dir, "discord-galen-nothere")

      FakeHub.enabled = false
      assert_empty Discord::Message.send(:moved_thread_base, dir, "discord-galen-12345678")
    end
  end

  def test_received_message_runs_as_relayed_with_this_machines_token
    seen = nil
    accept = ->(message, agent_key, token, bot_user_id, **opts) { seen = [message, agent_key, token, bot_user_id, opts] }
    payload = { "agent_key" => "galen", "bot_user_id" => "111", "bot_username" => "galen-bot",
                "message" => { "id" => "msg1" }, "verdict" => { "mentioned" => true, "in_own_thread" => false } }

    Discord::Message.stub(:accept, accept) { Routing.receive_message(payload) }

    assert_equal [{ "id" => "msg1" }, "galen", "Bot_galen", "111"], seen.first(4)
    assert seen.last[:relayed]
    assert seen.last[:mentioned]
    refute seen.last[:in_own_thread]
    assert_equal "111", Discord::Gateway.bot_user_id("galen")
    assert_equal "galen-bot", Discord::Gateway.bot_username("galen")
  end

  def test_received_message_for_an_agent_without_a_token_is_dropped
    called = false
    Discord::Message.stub(:accept, ->(*, **) { called = true }) do
      Routing.receive_message({ "agent_key" => "kaylee", "bot_user_id" => "333", "message" => {} })
    end
    refute called
  end

  def test_reply_names_the_machine_that_wrote_it
    sent = []
    file = File.join(TEST_BRAINIAC_DIR, "footer-test.md")
    File.write(file, "Deck's clear.")
    meta = { "channel_id" => "thread1", "message_id" => "msg1", "agent_key" => "galen", "agent_name" => "Galen",
             "is_thread" => true, "machine" => "mini" }

    Discord::Api.stub(:send_long_message, ->(_channel, text, **) { sent << text }) do
      Discord::Delivery.send(:deliver_response_content, file, meta, "Bot_galen")
      Discord::Delivery.send(:deliver_response_content, file, meta.except("machine"), "Bot_galen")
    end

    assert_equal ["Deck's clear.\n-# 🖥️ ran on mini", "Deck's clear."], sent
  end
end
