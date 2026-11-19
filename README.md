# brainiac-discord

Discord bot plugin for [Brainiac](https://github.com/stowzilla/brainiac) — the AI agent orchestration platform.

Each agent gets its own Discord bot. Users @mention @Galen or @GLaDOS directly — no shared bot, no agent name detection needed.

## Features

- **Per-agent bots** — each agent with a `DISCORD_BOT_TOKEN` gets its own WebSocket gateway connection
- **Session supersede** — follow-up messages within 60s kill the previous run and restart with updated context
- **Cancel via ❌** — react to cancel an active agent session
- **Thinking peek** — react ❔/❓ to see the last 10/20 lines of agent output
- **Thinking stream** — react 🧠 to get the full agent log streamed to a thread
- **Emoji feedback** — non-reserved emoji reactions are logged as feedback to the agent's persona
- **Thread isolation** — conversations get their own threads with worktree persistence
- **Forum support** — cron jobs can post to forum channels
- **GIF support** — agents can search and embed GIFs via Klipy API (formerly GIPHY)
- **Draft delivery** — file-based response delivery survives server restarts

## Installation

```bash
brainiac install discord
brainiac restart
```

Or for local development:

```bash
brainiac install discord --path ~/Code/brainiac-discord
brainiac restart
```

## Setup

### Adding an agent (recommended)

```bash
brainiac agent create "Galen" --local --avatar galen.png --description-file galen.md
```

Discord has no API for creating applications, so there's one manual step: the plugin opens the [developer portal](https://discord.com/developers/applications), you click **New Application** (name it after the agent) → **Bot** → **Reset Token**, and paste the token once. Everything else is automated:

- Bot username and avatar, app icon and description (from `--avatar` / `--description-file`)
- **Message Content** intent enabled
- `DISCORD_BOT_TOKEN` saved to the agent's `env` in `~/.brainiac/agents.json`
- The bot's user ID added to `user_mappings` in `~/.brainiac/discord.json`
- Server invite link printed and opened

A running server starts the new bot immediately — no restart needed.

For an existing agent, an interrupted create, or after installing this plugin, run `brainiac agent setup galen` (add `--only discord` to run just this plugin). It's safe to re-run: steps already done are skipped, and if the token is lost it sends you straight to the existing app's Bot tab. Use `--no-browser` to print links instead of opening them, or `--skip discord` to leave Discord out.

### Manual setup (alternative)

#### 1. Create Discord Applications

Create one Discord application per agent at https://discord.com/developers/applications:

1. Click "New Application", name it after the agent
2. Go to "Bot" tab → enable **Message Content Intent**
3. Click "Reset Token" and copy the bot token

#### 2. Register Tokens

```bash
brainiac discord token galen "BOT_TOKEN_FOR_GALEN"
brainiac discord token glados "BOT_TOKEN_FOR_GLADOS"
```

This only sets `DISCORD_BOT_TOKEN`; add the bot's user ID to `user_mappings` (see [Configuration](#configuration)) so other agents can @mention it. Restart a running server (`brainiac restart`) to pick up new tokens.

#### 3. Invite Bots

Use the OAuth2 URL Generator with `bot` scope and these permissions:
- View Channels, Send Messages, Embed Links, Attach Files, Read Message History
- Add Reactions, Manage Threads, Create Public Threads, Send Messages in Threads

Permission integer: `326417632320`

### Configure

Set a default project:
```bash
brainiac discord default marketplace
```

Map channels to projects:
```bash
brainiac discord map 1234567890 brainiac
```

### Start

```bash
brainiac server
```

All bots connect automatically as background threads.

## Commands

```
brainiac discord setup                         Check config and print next steps
brainiac discord config                        Show discord.json
brainiac discord default <project>             Set default project for all channels
brainiac discord map <channel-id> <project>    Map a specific channel to a project
brainiac discord owner [<discord-user-id>]     Set/show machine owner
brainiac discord token <agent-key> <token>     Set an agent's DISCORD_BOT_TOKEN
brainiac discord status                        Bot status (via the running server)
```

## Configuration

Stored in `~/.brainiac/discord.json`:

```json
{
  "default_project": "marketplace",
  "owner_discord_id": "YOUR_DISCORD_USER_ID",
  "channel_mappings": {
    "0987654321": { "project": "brainiac" }
  },
  "user_mappings": {
    "Andy": "123456789012345678"
  },
  "authorized_role_ids": [],
  "authorized_user_ids": [],
  "giphy_api_key": null,
  "klipy_api_key": "your-klipy-api-key"
}
```

- `user_mappings` — display name → Discord user ID, for humans and agent bots (`agent create` adds the bot's entry)
- `authorized_user_ids` / `authorized_role_ids` — who may talk to the agents; both empty allows everyone
- `role_mappings` — optional agent display name → Discord role ID, so @mentioning a role reaches that agent (when set, these role IDs replace `authorized_role_ids`)
- `klipy_api_key` — enables GIF search (`giphy_api_key` is still read as a fallback)

Bot tokens live in `~/.brainiac/agents.json` as each agent's `env.DISCORD_BOT_TOKEN`, not in `discord.json`.

## Multi-machine

When Brainiac runs on several machines behind a `brainiac-hub`, only one of them (the leader) opens the Discord gateway connections. Two machines holding the same bot's gateway would both answer every message. The plugin follows the core's `:hub_leader_acquired` and `:hub_leader_lost` hooks: it starts every bot when this machine becomes the leader and closes them when it stops being the leader.

A machine that is not the leader can still post to Discord, because posting uses the REST API and the token in `agents.json`. Without a hub configured, nothing changes.

### Sending work to a machine

The leader hears every message and decides which machine runs it:

1. **`[machine:<name>]` in the message** sends it to that machine. In a thread, the tag also moves the thread there.
2. **A thread stays with its machine.** The machine that holds a thread's worktree owns it (hub key `discord:<agent>:<thread id>`), and follow-ups go back to it without a tag.
3. Anything else runs on the leader.

```
@Galen [machine:mini] fix the flaky login test
```

The leader hands the raw message to the other machine through the hub. That machine runs the agent in its own worktree and posts the reply itself. Each reply ends with a small `ran on <machine>` line; set `"machine_footer": false` in `discord.json` to drop it.

What the leader tells you in the channel:

| Situation | What happens |
|-----------|--------------|
| The tag names a machine the hub has never seen | Nothing runs. The leader lists the known machines |
| The machine you asked for is offline, new conversation | The hub's next machine by priority runs it, and the leader says which |
| The machine you asked for is offline, existing thread | The thread stays with its owner, and the leader says so |
| The thread's owner is offline | The message waits in the hub for it. Send it again with `[machine:<name>]` to move the thread |
| The hub cannot be reached while handing work over | Nothing runs. Send it again |

Messages sent while a session is running, and the ❌ ❔ ❓ 🧠 reactions, follow the message to the machine running it. A thread being archived is passed to the machine that holds its worktree so it can clean up.

Limits:

- Every machine that may be asked needs the agent in `agents.json` with the same `DISCORD_BOT_TOKEN`, the same `discord.json` (channel-to-project mappings, authorized users), the project registered, and the CLI logged in. A machine without the agent's token ignores the work and the channel sees no reply.
- Moving a thread carries over only what was pushed. The new machine makes its own worktree from the thread's branch on the remote (`discord-<agent>-<id>`), or from the default branch if nothing was pushed. A machine that already has the thread's branch (the thread is coming back to it) reuses its old worktree as it was, so pull there if another machine pushed since. The old machine keeps its worktree until the thread is archived.
- Direct messages have no thread, so they run on the leader unless each one carries the tag.
- The leader remembers which messages it handed off in memory. After the leader restarts or changes, reactions on those older messages are not forwarded.
- Fork reactions and emoji feedback are handled on the leader.
- A thread keeps its machine after it is archived and its worktree removed; the next message goes back there and gets a fresh worktree. The hub forgets an owner after 180 days without use, or right away with `brainiac hub release discord:<agent>:<thread id>`.
- If the hub is down when the leader asks who owns a thread, it gets no answer and runs an untagged message itself.

Every machine needs this version of the plugin. See `docs/multi-machine.md` in Brainiac.

## Development

```bash
cd ~/Code/brainiac-discord
bundle install
rake test
rake rubocop
```

## License

MIT
