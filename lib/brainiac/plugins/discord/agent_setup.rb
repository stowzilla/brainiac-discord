# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "uri"

module Brainiac
  module Plugins
    module Discord
      # Provisions a Discord bot for a new brainiac agent (`brainiac agent create`
      # / `brainiac agent setup`).
      #
      # Discord has no API for creating applications, so the one manual step is
      # "New Application → Bot → Reset Token" in the developer portal. Given that
      # token, everything else is automated: bot username + avatar, app icon +
      # description, the Message Content intent, the token in agents.json, the
      # user_mappings entry, and the server invite link.
      module AgentSetup
        API_BASE = "https://discord.com/api/v10"
        PORTAL_URL = "https://discord.com/developers/applications"

        # Application flags that PATCH /applications/@me is allowed to change.
        GATEWAY_PRESENCE_LIMITED = 1 << 13
        GATEWAY_GUILD_MEMBERS_LIMITED = 1 << 15
        GATEWAY_MESSAGE_CONTENT_LIMITED = 1 << 19
        EDITABLE_FLAGS = GATEWAY_PRESENCE_LIMITED | GATEWAY_GUILD_MEMBERS_LIMITED | GATEWAY_MESSAGE_CONTENT_LIMITED

        # View channels, send/read messages, embeds, files, reactions, threads.
        BOT_PERMISSIONS = [10, 11, 14, 15, 16, 6, 34, 35, 38].sum { |bit| 1 << bit }

        APP_DESCRIPTION_LIMIT = 400
        IMAGE_TYPES = { ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
                        ".gif" => "image/gif", ".webp" => "image/webp" }.freeze

        class << self
          def run(agent_key, entry)
            display_name = entry["display_name"] || agent_key.capitalize
            token = registry.dig(agent_key, "env", "DISCORD_BOT_TOKEN")

            if token && discord_config.dig("user_mappings", display_name)
              puts "  [Discord] ✓ #{display_name} already has a bot (skipping)"
              sync_installed_apps(token)
              return
            end

            existing_id = discord_config.dig("user_mappings", display_name)
            token ||= prompt_for_token(display_name, entry["open_browser"], existing_id)
            return unless token

            me = request(:get, "/users/@me", token)
            unless me&.dig("id")
              puts "  [Discord] ✗ Discord rejected that token — re-run: brainiac agent setup #{agent_key}"
              return
            end

            avatar = image_data_uri(entry["avatar_path"])
            update_bot_user(me, display_name, avatar, token)
            app = request(:get, "/applications/@me", token) || {}
            update_application(app, entry["description"], avatar, token)

            save_token(agent_key, token)
            save_user_mapping(display_name, me["id"])
            puts "  [Discord] ✓ Saved DISCORD_BOT_TOKEN and user_mappings[#{display_name}] = #{me["id"]}"
            puts "  [Discord] Invite #{display_name} to your server:"
            puts "    #{invite_url(app["id"] || me["id"])}"
            open_url(invite_url(app["id"] || me["id"])) if entry["open_browser"]

            sync_installed_apps(token)
          end

          private

          # Backfill user_mappings for every OTHER app/bot already installed in the
          # guild — the ones this brainiac instance didn't create. Without this an
          # agent only knows about bots it provisioned itself, so a tag like
          # "@Judge Dredd" for an app from another instance renders as plain text
          # with no ID to route to. Sweeping the guild's members (bots included)
          # gives each installed app a name→id mapping so the mention roster and
          # tag detection at least know it exists.
          #
          # Best-effort and non-fatal: needs the SERVER MEMBERS intent and a
          # guild_id in discord.json. Only adds names not already mapped; never
          # overwrites a hand-set entry.
          def sync_installed_apps(token)
            guild_id = discord_config["guild_id"]
            return unless guild_id

            bots = fetch_guild_bots(guild_id, token)
            return if bots.nil?

            existing = discord_config["user_mappings"] || {}
            added = bots.reject { |name, _id| existing.key?(name) }
            if added.empty?
              puts "  [Discord] ✓ Installed apps already mapped (#{bots.size} bot(s) in server)"
              return
            end

            added.each { |name, id| save_user_mapping(name, id) }
            puts "  [Discord] ✓ Discovered #{added.size} installed app(s): #{added.keys.join(", ")}"
          end

          # Returns { bot_display_name => user_id } for every bot in the guild, or
          # nil when the member list can't be fetched (missing intent, bad token,
          # no permission). Humans are skipped — only user["bot"] members count.
          def fetch_guild_bots(guild_id, token)
            members = request(:get, "/guilds/#{guild_id}/members?limit=1000", token)
            unless members.is_a?(Array)
              puts "  [Discord] ⚠ Couldn't list installed apps — enable the SERVER MEMBERS intent (Bot tab → Privileged Gateway Intents)"
              return nil
            end

            members.each_with_object({}) do |member, acc|
              user = member["user"]
              next unless user && user["bot"]

              name = user["global_name"] || user["username"]
              id = user["id"]
              acc[name] = id if name && id
            end
          end

          # With a user_mappings entry the app already exists (the token was lost
          # or rotated), so send the user straight to its Bot tab instead of
          # "New Application". A bot's user ID is its application ID.
          def prompt_for_token(display_name, browser, existing_id = nil)
            return nil unless $stdin.tty?

            url = existing_id ? "#{PORTAL_URL}/#{existing_id}/bot" : PORTAL_URL
            puts ""
            puts "  [Discord] Opening the developer portal in your browser…" if browser && open_url(url)
            if existing_id
              puts "  [Discord] #{display_name} already has a Discord app, but its bot token isn't saved."
              puts "    #{url} → Reset Token → copy it"
            else
              puts "  [Discord] Create a bot for #{display_name} (the only manual step):"
              puts "    1. #{PORTAL_URL} → New Application → name it \"#{display_name}\""
              puts "    2. Bot tab → Reset Token → copy it"
              puts "  Name, avatar, description and Message Content intent are set automatically."
            end
            print "  Bot token (blank to skip): "
            token = read_secret
            puts ""
            token.nil? || token.empty? ? nil : token
          end

          # Best-effort: launch the default browser without blocking on it.
          # Returns false when no launcher is available (headless, SSH, ...).
          def open_url(url)
            launcher = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
            pid = Process.spawn(launcher, url, %i[out err] => File::NULL)
            Process.detach(pid)
            true
          rescue SystemCallError
            false
          end

          def read_secret
            require "io/console"
            $stdin.noecho(&:gets)&.strip
          rescue Errno::ENOTTY, NoMethodError
            $stdin.gets&.strip
          end

          def update_bot_user(bot_user, display_name, avatar, token)
            body = {}
            body[:username] = display_name unless bot_user["username"] == display_name
            body[:avatar] = avatar if avatar
            return if body.empty?

            if request(:patch, "/users/@me", token, body)
              puts "  [Discord] ✓ Bot user: #{body.keys.join(" + ")} updated"
            else
              puts "  [Discord] ⚠ Couldn't update bot #{body.keys.join("/")} (username taken or rate limited?) — set it in the portal"
            end
          end

          def update_application(app, description, avatar, token)
            body = {}
            body[:description] = truncate(description, APP_DESCRIPTION_LIMIT) if description
            body[:icon] = avatar if avatar
            if body.any? && !request(:patch, "/applications/@me", token, body)
              puts "  [Discord] ⚠ Couldn't update app #{body.keys.join("/")} — set it in the portal"
            end

            # Separate request so a flags rejection doesn't lose the icon/description.
            flags = ((app["flags"] || 0) & EDITABLE_FLAGS) | GATEWAY_MESSAGE_CONTENT_LIMITED
            if request(:patch, "/applications/@me", token, { flags: flags })
              puts "  [Discord] ✓ App #{(body.keys + [:message_content_intent]).join(" + ")} set"
            else
              puts "  [Discord] ⚠ Couldn't enable Message Content intent — Bot tab → Privileged Gateway Intents"
            end
          end

          def invite_url(client_id)
            "https://discord.com/oauth2/authorize?client_id=#{client_id}&scope=bot&permissions=#{BOT_PERMISSIONS}"
          end

          def image_data_uri(path)
            return nil unless path && File.file?(path)

            mime = IMAGE_TYPES[File.extname(path).downcase]
            return nil unless mime

            "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
          end

          def truncate(text, limit)
            text = text.strip
            text.length > limit ? "#{text[0, limit - 1].rstrip}…" : text
          end

          # Returns the parsed body on 2xx, nil otherwise.
          def request(method, path, token, body = nil)
            uri = URI("#{API_BASE}#{path}")
            klass = { get: Net::HTTP::Get, patch: Net::HTTP::Patch }.fetch(method)
            req = klass.new(uri)
            req["Authorization"] = "Bot #{token}"
            req["Content-Type"] = "application/json"
            req["User-Agent"] = "DiscordBot (https://github.com/stowzilla/brainiac-discord, 1.0)"
            req.body = body.to_json if body

            response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
            return nil unless response.is_a?(Net::HTTPSuccess)

            response.body.to_s.empty? ? {} : JSON.parse(response.body)
          rescue StandardError
            nil
          end

          def brainiac_dir
            ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
          end

          def registry_file = File.join(brainiac_dir, "agents.json")
          def config_file = File.join(brainiac_dir, "discord.json")

          def registry
            File.exist?(registry_file) ? JSON.parse(File.read(registry_file)) : {}
          end

          def discord_config
            File.exist?(config_file) ? JSON.parse(File.read(config_file)) : {}
          end

          def save_token(agent_key, token)
            reg = registry
            reg[agent_key] ||= {}
            reg[agent_key]["env"] ||= {}
            reg[agent_key]["env"]["DISCORD_BOT_TOKEN"] = token
            FileUtils.mkdir_p(brainiac_dir)
            File.write(registry_file, JSON.pretty_generate(reg))
          end

          def save_user_mapping(display_name, user_id)
            config = discord_config
            config["user_mappings"] ||= {}
            config["user_mappings"][display_name] = user_id
            File.write(config_file, JSON.pretty_generate(config))
          end
        end
      end
    end
  end
end
