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
- **GIF support** — agents can search and embed GIFs via GIPHY API
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

### 1. Create Discord Applications

Create one Discord application per agent at https://discord.com/developers/applications:

1. Click "New Application", name it after the agent
2. Go to "Bot" tab → enable **Message Content Intent**
3. Copy the bot token

### 2. Register Tokens

```bash
brainiac discord token galen "BOT_TOKEN_FOR_GALEN"
brainiac discord token glados "BOT_TOKEN_FOR_GLADOS"
```

### 3. Invite Bots

Use the OAuth2 URL Generator with `bot` scope and these permissions:
- Send Messages, Create Public Threads, Send Messages in Threads
- Add Reactions, Read Message History

Permission integer: `326417591296`

### 4. Configure

Set a default project:
```bash
brainiac discord default marketplace
```

Map channels to projects:
```bash
brainiac discord map 1234567890 brainiac
```

### 5. Start

```bash
brainiac server
```

All bots connect automatically as background threads.

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
  "giphy_api_key": "your-giphy-api-key"
}
```

## Development

```bash
cd ~/Code/brainiac-discord
bundle install
rake test
rake rubocop
```

## License

MIT
