# frozen_string_literal: true

require "websocket-client-simple"
require "websocket"

module Brainiac
  module Plugins
    module Discord
      # Discord WebSocket gateway connections.
      #
      # Each agent with a DISCORD_BOT_TOKEN gets its own persistent WebSocket
      # connection. The gateway dispatches MESSAGE_CREATE, MESSAGE_UPDATE,
      # and MESSAGE_REACTION_ADD events to handler functions.
      module Gateway
        GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"
        GATEWAY_QUERY = "?v=10&encoding=json"

        # Reconnect backoff (seconds). A normal disconnect starts at BASE and
        # doubles up to CAP; a handshake rejection (HTTP non-101, e.g. Discord
        # returning 429 to the WebSocket upgrade) starts higher to avoid a
        # reconnect storm across many bots hammering the gateway in lockstep.
        BACKOFF_BASE = 5
        BACKOFF_HANDSHAKE_BASE = 30
        BACKOFF_CAP = 300

        # Per-bot state: { agent_key => { token:, user_id:, status:, thread: } }
        @bots = {}
        @bots_mutex = Mutex.new
        @all_ready_logged = false

        class << self
          attr_reader :bots, :bots_mutex

          def bot_count
            @bots_mutex.synchronize { @bots.size }
          end

          # Iterate over bots under mutex.
          def each_bot(&)
            @bots_mutex.synchronize do
              @bots.each(&)
            end
          end

          # Get a bot's token.
          def bot_token(agent_key)
            @bots_mutex.synchronize { @bots.dig(agent_key, :token) }
          end

          # Get a bot's user_id.
          def bot_user_id(agent_key)
            @bots_mutex.synchronize { @bots.dig(agent_key, :user_id) }
          end

          # Collect all agent Discord bot tokens from the registry.
          # Returns { "galen" => "token...", "glados" => "token..." }
          def discord_bot_tokens
            tokens = {}
            AGENT_REGISTRY.each do |key, entry|
              next unless entry.is_a?(Hash)

              token = (entry["env"] || {})["DISCORD_BOT_TOKEN"]
              next unless token

              tokens[key] = token
            end
            tokens
          end

          # Start all per-agent Discord bots.
          def start_all!
            tokens = discord_bot_tokens
            if tokens.empty?
              LOG.info "[Discord] No agents have DISCORD_BOT_TOKEN configured — Discord disabled" if defined?(LOG)
              return
            end

            LOG.info "[Discord] Starting #{tokens.size} bot(s): #{tokens.keys.join(", ")}" if defined?(LOG)

            @bots_mutex.synchronize do
              tokens.each do |agent_key, token|
                @bots[agent_key] = { token: token, status: "starting", user_id: nil }
              end
            end

            tokens.each do |agent_key, token|
              start_gateway_for(agent_key, token)
              sleep 1 # Stagger connections to avoid rate limits
            end
          end

          # Start a single bot gateway connection dynamically (e.g. after agent is added).
          # No-op if the bot is already running.
          def start_bot!(agent_key, token)
            @bots_mutex.synchronize do
              return if @bots[agent_key]

              @bots[agent_key] = { token: token, status: "starting", user_id: nil }
            end
            start_gateway_for(agent_key, token)
          end

          # Stop a bot gateway connection (e.g. after agent is removed).
          # Removes it from the bots hash so it won't be matched in detect_sender_agent.
          def stop_bot!(agent_key)
            info = @bots_mutex.synchronize { @bots.delete(agent_key) }
            return unless info

            info[:thread]&.kill
            LOG.info "[Discord] Gateway stopped for #{agent_key}" if defined?(LOG)
          end

          # Summary of all bot statuses for the API endpoint.
          def bots_status
            @bots_mutex.synchronize do
              @bots.transform_values do |info|
                { status: info[:status], user_id: info[:user_id] }
              end
            end
          end

          # Detect if a message author is a known bot (local or remote).
          # Returns the agent_key of the sender, or nil if unknown.
          def detect_sender_agent(author, current_agent_key)
            sender_id = author["id"]
            sender_agent_key = nil

            @bots_mutex.synchronize do
              @bots.each do |key, info|
                if info[:user_id] == sender_id && key != current_agent_key
                  sender_agent_key = key
                  break
                end
              end
            end

            unless sender_agent_key
              Config.user_mappings.each do |name, discord_id|
                if discord_id == sender_id
                  sender_agent_key = name.downcase
                  break
                end
              end
            end

            if !sender_agent_key && defined?(LOG)
              LOG.info "[Discord:#{current_agent_key}] Ignoring unknown bot: id=#{sender_id}, username=#{author["username"]}"
            end

            sender_agent_key
          end

          private

          # Resolve the gateway URL to connect to, and honor Discord's session
          # start limits. Queries GET /gateway/bot (authenticated) which returns
          # the recommended WebSocket URL plus session_start_limit. If the bot
          # has exhausted its identify allowance, sleep until the window resets
          # before returning so we don't burn reconnects against a hard limit.
          # Falls back to the hardcoded GATEWAY_URL if the call fails.
          def resolve_gateway_url(bot_token, agent_display)
            info = Api.request(:get, "/gateway/bot", token: bot_token, log_errors: false)
            unless info.is_a?(Hash) && info["url"]
              LOG.warn "[Discord:#{agent_display}] Could not fetch /gateway/bot, using default URL" if defined?(LOG)
              return GATEWAY_URL
            end

            honor_session_limit(info["session_start_limit"], agent_display)

            "#{info["url"]}/#{GATEWAY_QUERY}"
          rescue StandardError => e
            LOG.warn "[Discord:#{agent_display}] /gateway/bot lookup failed: #{e.message}, using default URL" if defined?(LOG)
            GATEWAY_URL
          end

          # If Discord reports no remaining identifies, wait out the reset window.
          def honor_session_limit(limit, agent_display)
            return unless limit.is_a?(Hash)

            remaining = limit["remaining"].to_i
            return if remaining.positive?

            reset_after_s = (limit["reset_after"].to_i / 1000.0).ceil
            reset_after_s = 1 if reset_after_s <= 0
            LOG.warn "[Discord:#{agent_display}] Session start limit exhausted, waiting #{reset_after_s}s" if defined?(LOG)
            sleep reset_after_s
          end

          # Exponential backoff with full jitter, capped. `attempt` is 0-based.
          def backoff_delay(attempt, base)
            capped = [base * (2**attempt), BACKOFF_CAP].min
            # Full jitter: random between base and the capped ceiling.
            rand(base.to_f..capped.to_f).round(1)
          end

          def start_gateway_for(agent_key, bot_token)
            thread = Thread.new do
              agent_display = agent_display_name(agent_key) || agent_key.capitalize
              bot_user_id = nil
              attempt = 0

              loop do
                bot_user_id = run_gateway_connection(agent_key, agent_display, bot_token, bot_user_id)
                # A clean return means the connection was established at least
                # once; reset backoff so a later transient drop recovers fast.
                attempt = 0
                delay = backoff_delay(attempt, BACKOFF_BASE)
                LOG.info "[Discord:#{agent_display}] Reconnecting in #{delay}s..." if defined?(LOG)
                sleep delay
              rescue WebSocket::Error::Handshake::InvalidStatusCode => e
                @bots_mutex.synchronize do
                  @bots[agent_key][:status] = "error" if @bots[agent_key]
                end
                delay = backoff_delay(attempt, BACKOFF_HANDSHAKE_BASE)
                attempt += 1
                if defined?(LOG)
                  LOG.error "[Discord:#{agent_display}] Gateway handshake rejected (#{e.message}) — " \
                            "likely rate limited; backing off #{delay}s"
                end
                sleep delay
              rescue StandardError => e
                @bots_mutex.synchronize do
                  @bots[agent_key][:status] = "error" if @bots[agent_key]
                end
                delay = backoff_delay(attempt, BACKOFF_BASE)
                attempt += 1
                LOG.error "[Discord:#{agent_display}] Gateway error: #{e.message}, reconnecting in #{delay}s..." if defined?(LOG)
                sleep delay
              end
            end
            @bots_mutex.synchronize { @bots[agent_key][:thread] = thread if @bots[agent_key] }
          end

          def run_gateway_connection(agent_key, agent_display, bot_token, bot_user_id)
            # Capture module-level ivars in local variables so the event_emitter
            # blocks (which run via instance_exec on the WS client) can access them.
            bots = @bots
            bots_mutex = @bots_mutex

            bots_mutex.synchronize do
              bots[agent_key] ||= {}
              bots[agent_key][:status] = "connecting"
              bots[agent_key][:token] = bot_token
            end

            # The WebSocket handshake runs in websocket-client-simple's own reader
            # thread, so a non-101 response surfaces via the :error callback rather
            # than raising here. Capture it and re-raise after the connection wait
            # so the reconnect loop can apply handshake-specific backoff.
            handshake_error = nil

            gateway_url = resolve_gateway_url(bot_token, agent_display)
            LOG.debug "[Discord:#{agent_display}] Connecting to #{gateway_url}" if defined?(LOG) && LOG.respond_to?(:debug)
            heartbeat_thread = nil
            last_sequence = nil
            ws = WebSocket::Client::Simple.connect(gateway_url)

            ws.on :message do |msg|
              next if msg.data.nil? || msg.data.empty?

              payload = JSON.parse(msg.data)
              last_sequence = payload["s"] if payload["s"]
              heartbeat_thread, bot_user_id = Gateway.send(
                :handle_gateway_op,
                ws, payload, agent_key, agent_display, bot_token, bot_user_id, heartbeat_thread, last_sequence
              )
            rescue StandardError => e
              LOG.error "[Discord:#{agent_display}] Gateway message error: #{e.message}" if defined?(LOG)
            end

            ws.on :open do
              LOG.debug "[Discord:#{agent_display}] WebSocket connected" if defined?(LOG) && LOG.respond_to?(:debug)
            end

            ws.on :close do |_e|
              bots_mutex.synchronize do
                bots[agent_key][:status] = "disconnected" if bots[agent_key]
              end
              LOG.warn "[Discord:#{agent_display}] WebSocket closed" if defined?(LOG)
              heartbeat_thread&.kill
            end

            ws.on :error do |e|
              handshake_error = e if e.is_a?(WebSocket::Error::Handshake::InvalidStatusCode)
              LOG.error "[Discord:#{agent_display}] WebSocket error: #{e.message}" if defined?(LOG)
            end

            wait_for_disconnect(ws, agent_display) { handshake_error }

            # If the connection never opened because Discord rejected the upgrade,
            # propagate so the caller backs off harder instead of tight-looping.
            raise handshake_error if handshake_error && !ws.open?

            bot_user_id
          end

          # Block until the socket closes. Returns promptly if a handshake error
          # is reported (the socket never opens in that case). Backoff between
          # reconnects is owned by the caller (start_gateway_for).
          def wait_for_disconnect(websocket, agent_display)
            # Give the handshake a brief window to complete before deciding the
            # socket is dead, so we don't treat a still-connecting socket as lost.
            grace = 10
            grace.times do
              sleep 0.5
              break if websocket.open? || (block_given? && yield)
            end

            loop do
              return if block_given? && yield && !websocket.open?

              break unless websocket.open?

              sleep 1
            end

            LOG.info "[Discord:#{agent_display}] Connection lost" if defined?(LOG)
          end

          def handle_gateway_op(websocket, payload, agent_key, agent_display, bot_token, bot_user_id, heartbeat_thread, last_sequence)
            op = payload["op"]
            data = payload["d"]

            case op
            when 10
              heartbeat_thread = start_heartbeat(websocket, data["heartbeat_interval"], agent_display, last_sequence)
              send_identify(websocket, bot_token, agent_display)
            when 0
              bot_user_id = handle_dispatch(payload, data, agent_key, agent_display, bot_token, bot_user_id)
            when 1
              websocket.send({ op: 1, d: last_sequence }.to_json)
            when 7
              LOG.info "[Discord:#{agent_display}] Reconnect requested" if defined?(LOG)
              websocket.close
            when 9
              LOG.warn "[Discord:#{agent_display}] Invalid session, re-identifying in 5s" if defined?(LOG)
              sleep 5
              send_identify(websocket, bot_token, agent_display)
            when 11 then nil
            end

            [heartbeat_thread, bot_user_id]
          end

          def start_heartbeat(websocket, interval_ms, agent_display, last_sequence)
            LOG.debug "[Discord:#{agent_display}] Gateway connected, heartbeat: #{interval_ms}ms" if defined?(LOG) && LOG.respond_to?(:debug)
            Thread.new do
              loop do
                sleep(interval_ms / 1000.0)
                websocket.send({ op: 1, d: last_sequence }.to_json)
              end
            end
          end

          def send_identify(websocket, bot_token, agent_display)
            LOG.debug "[Discord:#{agent_display}] Sending IDENTIFY" if defined?(LOG) && LOG.respond_to?(:debug)
            websocket.send({
              op: 2,
              d: {
                token: bot_token,
                intents: 46_593,
                properties: { os: RUBY_PLATFORM, browser: "brainiac", device: "brainiac" }
              }
            }.to_json)
          end

          def handle_dispatch(payload, data, agent_key, agent_display, bot_token, bot_user_id)
            case payload["t"]
            when "READY"
              bot_user_id = data.dig("user", "id")
              mark_bot_ready(agent_key, agent_display, bot_user_id, data)
            when "MESSAGE_CREATE"
              Thread.new do
                Message.handle(data, agent_key, bot_token, bot_user_id)
              rescue StandardError => e
                LOG.error "[Discord:#{agent_display}] Error handling message: #{e.message}\n#{e.backtrace.first(3).join("\n")}" if defined?(LOG)
              end
            when "MESSAGE_UPDATE"
              if data["edited_timestamp"]
                Thread.new do
                  Message.handle(data, agent_key, bot_token, bot_user_id)
                rescue StandardError => e
                  if defined?(LOG)
                    LOG.error "[Discord:#{agent_display}] Error handling message update: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
                  end
                end
              end
            when "MESSAGE_REACTION_ADD"
              Thread.new do
                Reactions.handle(data, agent_key, bot_token, bot_user_id)
              rescue StandardError => e
                LOG.error "[Discord:#{agent_display}] Error handling reaction: #{e.message}\n#{e.backtrace.first(3).join("\n")}" if defined?(LOG)
              end
            when "THREAD_UPDATE"
              if data.dig("thread_metadata", "archived")
                Thread.new do
                  ThreadCleanup.handle_archive(data, agent_key, agent_display)
                rescue StandardError => e
                  if defined?(LOG)
                    LOG.error "[Discord:#{agent_display}] Error handling thread archive: " \
                              "#{e.message}\n#{e.backtrace.first(3).join("\n")}"
                  end
                end
              end
            when "THREAD_DELETE"
              Thread.new do
                ThreadCleanup.handle_archive(data, agent_key, agent_display)
              rescue StandardError => e
                if defined?(LOG)
                  LOG.error "[Discord:#{agent_display}] Error handling thread delete: " \
                            "#{e.message}\n#{e.backtrace.first(3).join("\n")}"
                end
              end
            end

            bot_user_id
          end

          def mark_bot_ready(agent_key, agent_display, bot_user_id, data)
            @bots_mutex.synchronize do
              @bots[agent_key][:user_id] = bot_user_id
              @bots[agent_key][:username] = data.dig("user", "username")
              @bots[agent_key][:status] = "ready"
            end
            guild_count = data["guilds"]&.size || 0
            LOG.info "[Discord] #{agent_display} ready (#{guild_count} #{guild_count == 1 ? "guild" : "guilds"})" if defined?(LOG)

            @bots_mutex.synchronize do
              if !@all_ready_logged && @bots.all? { |_, info| info[:status] == "ready" }
                @all_ready_logged = true
                LOG.info "[Discord] All bots connected." if defined?(LOG)
              end
            end
          end
        end
      end
    end
  end
end
