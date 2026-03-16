# Getting Started with Pembrook

Pembrook is a privacy-first personal AI agent that runs entirely on infrastructure you control.  
All communication is end-to-end encrypted via the [atPlatform](https://atsign.com) — no open inbound ports, no cloud relay, no plaintext credentials.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Register your atSigns](#2-register-your-atsigns)
3. [Clone & Install](#3-clone--install)
4. [Run the Setup Wizard](#4-run-the-setup-wizard)
5. [Start the Backend](#5-start-the-backend)
6. [Connect the Flutter App](#6-connect-the-flutter-app)
7. [Verify It Works](#7-verify-it-works)
8. [Chat History](#8-chat-history)
9. [Register & Sync Skills](#9-register--sync-skills)
10. [Enable MCP Servers (Optional)](#10-enable-mcp-servers-optional)
11. [Enable Bridges (Optional)](#11-enable-bridges-optional)
12. [Allow Additional Users](#12-allow-additional-users)
13. [Managing Policies](#13-managing-policies)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Dart SDK | ≥ 3.6 | [dart.dev/get-dart](https://dart.dev/get-dart) |
| Docker + Compose | Docker Desktop 4.x or Engine + Compose plugin v2 | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| Flutter SDK | ≥ 3.29 | [flutter.dev/install](https://flutter.dev/install) (for building the app) |
| Ollama | any | [ollama.com](https://ollama.com) — install on host **or** use bundled Docker option |
| atSigns | 2–3 | Free at [my.atsign.com](https://my.atsign.com/dashboard) |

---

## 2. Register your atSigns

Pembrook uses [atSigns](https://atsign.com) as cryptographic identities.  
You need **at minimum 2 atSigns**, and **never more than 3** — even for a fully loaded system with all bridges and all MCP servers.

### Why multiple atSigns?

The atPlatform's `sharedWith` notation (`@bob:key@alice`) requires the **sender and recipient to be different atSigns**.  
A single atSign cannot send a notification to itself — so the agent and the entity talking to the agent must be different identities.

| atSign role | Purpose | Minimum |
|---|---|---|
| `@agent` | The agent daemon on your server | **Required** |
| `@owner` | Your personal identity — Flutter app, CLI | **Required** |
| `@services` | **All** bridges (WhatsApp / Telegram / Discord / Slack) **and all** MCP servers share this one atSign | Only if using bridges or MCP servers |

> **One third atSign covers everything.** Bridges and MCP servers each filter by command prefix, so multiple services sharing the same atSign don't interfere with each other.  
> You do **not** need separate atSigns per bridge or per MCP server.

> **Can `@agent` be reused for bridges or MCP servers?** No. Bridges send messages *to* `@agent`, and the agent sends requests *to* MCP servers — the atPlatform forbids a sender and recipient being the same atSign. `@agent` must be its own distinct identity.

### Steps

1. Go to [my.atsign.com/dashboard](https://my.atsign.com/dashboard)
2. Click **Create a free atSign** for each identity you need
3. On the dashboard, click the atSign → **Download Keys** → save the `.atKeys` file

You will have files like:
```
@myagent_key.atKeys
@myowner_key.atKeys
@myservices_key.atKeys   ← only if you want bridges or MCP servers
```

Place them in `~/.atsign/keys/` — the standard location used by all atSign apps:
```
~/.atsign/keys/
  @myagent_key.atKeys
  @myowner_key.atKeys
  @myservices_key.atKeys
```

> **Security:** `~/.atsign/keys/` is your home directory and is never committed to git.  
> It is mounted **read-only** into Docker containers.

---

## 3. Clone & Install

```bash
git clone https://github.com/cconstab/pembrook.git
cd pembrook
mkdir -p ~/.atsign/keys
# Place your .atKeys files in ~/.atsign/keys/
```

---

## 4. Run the Setup Wizard

The setup wizard prompts for your atSigns, writes `.env`, and writes the required configuration AtKeys to your agent's atServer.

```bash
bash scripts/setup.sh
```

You will be asked:

| Prompt | Example answer |
|---|---|
| Agent atSign | `@myagent` |
| Owner atSign | `@myowner` |
| Agent .atKeys file path | `~/.atsign/keys/@myagent_key.atKeys` |
| Services atSign (optional) | `@myservices` |
| Services .atKeys file path | `~/.atsign/keys/@myservices_key.atKeys` |
| Ollama model | `qwen2.5:7b` |
| Extra allowed atSigns | *(leave blank)* |

The wizard will:
1. Validate all prerequisites
2. Write `.env` in the project root
3. Run `dart run agent/bin/init_config.dart` to write settings AtKeys to `@myagent`'s atServer

### Non-interactive mode (CI / server setup)

```bash
AGENT_AT_SIGN=@myagent \
OWNER_AT_SIGN=@myowner \
AGENT_KEYS_PATH=~/.atsign/keys/@myagent_key.atKeys \
SERVICES_AT_SIGN=@myservices \
SERVICES_KEYS_PATH=~/.atsign/keys/@myservices_key.atKeys \
bash scripts/setup.sh --non-interactive
```

### Manual configuration (power users)

Copy `.env.example` to `.env` and fill in the values manually, then run `init_config.dart` directly:

```bash
cp .env.example .env
# Edit .env with your values

cd agent
dart pub get
dart run bin/init_config.dart \
  --atsign @myagent \
  --key-file ~/.atsign/keys/@myagent_key.atKeys \
  --owner @myowner \
  --services-atsign @myservices \
  --ollama-model qwen2.5:7b \
  --verbose
```

---

## 5. Start the Backend

Pembrook needs Ollama for LLM inference. There are two options:

### Option A — Host Ollama (recommended)

Install Ollama on your machine from [ollama.com](https://ollama.com), then:

```bash
# Pull a model:
ollama pull qwen2.5:7b

# Start Ollama (if not already running as a service):
ollama serve
```

> **Linux only:** Ollama defaults to `127.0.0.1`. The agent container reaches your host via `host.docker.internal`, so Ollama must listen on all interfaces:
> ```bash
> OLLAMA_HOST=0.0.0.0 ollama serve
> # Or permanently via systemd:
> sudo systemctl edit ollama   # add: [Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"
> ```
> macOS and Windows Docker Desktop route `host.docker.internal` transparently — no change needed.

Then start the agent:

```bash
docker compose up -d
```

### Option B — Bundled Ollama (Ollama inside Docker)

No host install needed, but slower to start and uses more RAM.

```bash
# Pull the model first:
docker compose --profile bundled-ollama run --rm ollama ollama pull qwen2.5:7b

# Start with bundled Ollama (CPU):
docker compose --profile bundled-ollama up -d

# GPU — Linux + NVIDIA only:
docker compose --profile bundled-ollama -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

> Add `OLLAMA_BASE_URL=http://ollama:11434` to your `.env` when using the bundled option.

> Use a smaller model if RAM is limited:  
> `ollama pull qwen2.5:3b` (~2 GB) or `ollama pull phi4-mini` (~2.5 GB)

### Watch the logs:

```bash
docker compose logs -f agent
```

You should see output like:
```
[INFO] Gateway  — AllowList refreshed: [@myowner, @myservices]
[INFO] Gateway  — Gateway started on @myagent namespace=pembrook...
[INFO] Heartbeat — Pembrook agent is running.
```

### Stop:

```bash
docker compose down
```

---

## 6. Connect the Flutter App

```bash
cd app
flutter pub get
flutter run
```

On first launch the app shows an **Authenticate** screen:

1. Tap **Authenticate with atSign**
2. Enter your owner atSign: `@myowner`  
3. The app will open a browser tab to onboard the atSign (first time) or load keys from a previously onboarded device
4. After authentication, the app connects to `@myagent` automatically

> The app uses the `OWNER_AT_SIGN` you configured to find and talk to the agent atSign.  
> If you change the agent atSign, update **Settings → Agent atSign** in the app.

---

## 7. Verify It Works

Once the app is connected:

1. **Chat tab** → type a message → the agent should reply within a few seconds
2. **Audit tab** → you should see a `command` entry with `policyDecision: allowed`
3. **Settings tab** → should show the agent atSign as `@myagent` and status as `online`

From the terminal, you can also run a quick end-to-end check:

```bash
cd agent
dart run bin/init_config.dart \
  --atsign @myagent \
  --key-file ~/.atsign/keys/@myagent_key.atKeys \
  --owner @myowner \
  --verbose
```

If it exits cleanly, authentication and AtKey writing both work.

---

## 8. Chat History

The app stores every conversation locally so you can browse, restore, or delete past sessions.

### How it works

- Each conversation is assigned a unique ID when it begins.
- Messages are auto-saved to device storage (SharedPreferences) after every exchange.
- Up to **100 conversations** are retained; the oldest are pruned automatically.

### Using Chat History

| Action | How |
|---|---|
| Start a new conversation | Tap **➕** in the top-right of the Chat screen |
| Browse past conversations | Tap **🕐** (history icon) in the top-right |
| Restore a conversation | Open History → tap any session |
| Delete a conversation | Open History → swipe left on a session, or tap the delete icon |

> Past conversations are read-only when restored — you can review context but replies start a new session.

---

## 9. Register & Sync Skills

Skills extend the agent with external capabilities (e.g. web search, calendar, email).  
They are registered in the Flutter app and automatically synced to the running agent via an encrypted RPC channel.

### What is a Skill?

A skill is a **sandboxed Docker container** that the agent spawns on demand.  
Each skill exposes one or more actions via a simple stdin/stdout JSON protocol.  
The agent only invokes skills that are registered in its `SkillRegistry`.

The Docker image name is derived from the Skill ID:
```
pembrook-skill-<skillId>:latest
```

### Built-in skills

Three skills ship with Pembrook in the `skills/` directory:

| Skill ID | Directory | What it does | Network needed? |
|---|---|---|---|
| `email` | `skills/email/` | Send / list / read / delete email via SMTP + IMAP | Yes (SMTP/IMAP) |
| `calendar` | `skills/calendar/` | Read / create / update calendar events (CalDAV) | Yes |
| `web_search` | `skills/web_search/` | SearXNG or Brave web search + page fetcher | Yes |

> **Note:** Skills that need network access must be registered with **Requires network access** turned on (Step 2).  
> Without this, the sandbox runs with `--network=none` and SMTP/IMAP/HTTPS calls will fail silently.

### Step 1 — Build the skill Docker image

Dockerfiles are in each skill's directory. Run from the repo root on the same host as the agent:

```bash
# Email skill
docker build -t pembrook-skill-email:latest -f skills/email/Dockerfile .

# Calendar skill
docker build -t pembrook-skill-calendar:latest -f skills/calendar/Dockerfile .

# Web search skill
docker build -t pembrook-skill-web_search:latest -f skills/web_search/Dockerfile .
```

> The first build pulls the Dart SDK layer (~1 GB) — subsequent builds are cached.  
> The image must be present on the **Docker host** the agent container uses.  
> The agent gets access to Docker via the `/var/run/docker.sock` volume defined in `docker-compose.yml`.

### Step 2 — Register the skill in the app

1. Open the **Skills** tab in the app
2. Tap the **➕** FAB
3. Fill in:
   | Field | Example | Notes |
   |---|---|---|
   | Skill ID | `email` | Must match the image name: `pembrook-skill-<id>:latest` |
   | Skill atSign | `@myservices` | Can be your services atSign — no dedicated atSign needed |
   | Description | `Send and read emails via SMTP/IMAP` | Shown in the agent's tool list |
   | Version | `1.0.0` | Semantic version |
   | Requires network access | ✅ on | **Turn on for email, calendar, web_search** |
4. Tap **Register**

### Step 2b — Configure the skill (credentials)

After registering, tap the **⚙ tune** icon on the skill card to enter its credentials.  
These are stored **encrypted on your atServer** and never appear in logs.

**Email skill fields:**

| Field | Example |
|---|---|
| SMTP Host | `smtp.gmail.com` |
| SMTP Port | `587` |
| SMTP Username | `you@gmail.com` |
| SMTP Password | `your-app-password` |
| From Address | `you@gmail.com` |
| IMAP Host | `imap.gmail.com` |
| IMAP Port | `993` |
| IMAP Username | `you@gmail.com` |
| IMAP Password | `your-app-password` |

**Calendar skill fields:**

| Field | Example |
|---|---|
| Google OAuth2 Access Token | `ya29.xxxx` |
| Calendar ID | `primary` |

> Obtaining a Google OAuth2 access token: create an OAuth client in [Google Cloud Console](https://console.cloud.google.com/), enable the Calendar API, and run the installed-app OAuth flow to get a refresh/access token.

**Web Search skill fields:**

| Field | Example | Notes |
|---|---|---|
| SearXNG Base URL | `https://searx.example.com` | Your self-hosted SearXNG instance |
| Brave API Key | `BSA...` | Alternative: Brave Search API key |

> Use one or the other — if both are set, SearXNG takes precedence.

Tap **Save** in the sheet.  The config is immediately re-synced to the agent via RPC.

What happens behind the scenes:
1. The app writes the skill metadata (including config) to an AtKey on `@owner`'s atServer (for audit)
2. The app sends a `_sys.skill.install` RPC command to `@agent`
3. The agent registers the skill in its `SkillRegistry` and can now spawn the container on demand
4. At invocation time, the agent merges the stored config into the skill payload before spawning the container

### Step 3 — Use the skill

Just ask the agent naturally in chat:

> *"Send an email to bob@example.com with subject 'Hello' and body 'Test'"*  
> *"Show me my last 10 inbox messages"*  
> *"Search the web for the latest Dart release notes"*

The agent classifies the intent, looks up the matching skill, spawns the container with the payload, and returns the result.  
Destructive operations (e.g. `delete_email`) trigger a HITL approval request before execution.

### Enable / disable a skill

Toggle the switch next to any skill in the list.  
The change is immediately synced to the agent via `_sys.skill.install` with `enabled: false/true`.

### Remove a skill

Tap the delete icon on any skill.  
The app sends `_sys.skill.uninstall` to the agent, which removes it from the live `SkillRegistry`.

### `_sys.skill.*` RPC commands (reference)

| Command | Payload | Effect |
|---|---|---|
| `_sys.skill.install` | `{skillId, skillAtSign, description, version, enabled, trustScore, requiresNetwork, config}` | Add or update skill in registry |
| `_sys.skill.uninstall` | `{skillId}` | Remove skill from registry |
| `_sys.skill.list` | *(empty)* | Returns array of all registered skills |

> These commands are only accepted from atSigns in the agent's `allowList` (your `@owner` atSign).

---

## 10. Enable MCP Servers (Optional)

MCP (Model Context Protocol) servers give the agent access to external resources — home automation, databases, web browsing — over the atPlatform using dedicated atSigns.

### Available MCP servers

| Server | Purpose | Network needed? |
|---|---|---|
| `home` | Home Assistant — control lights, sensors, automations | Yes (HA REST API) |
| `database` | SQLite — structured data queries from the agent | No (local file) |
| `browser` | HTTP fetch + HTML text extraction; optional Playwright sidecar for screenshots/clicks | Yes (HTTPS) |

All three servers share the same `@services` atSign — no separate atSign per server is needed.

### Step 1 — Provision a services atSign (if you haven't already)

This is the same third atSign used by bridges.  
If you already set up `@myservices` for a bridge, **skip this step** — MCP servers reuse the same atSign.

If you haven't provisioned it yet:
1. Go to [my.atsign.com/dashboard](https://my.atsign.com/dashboard)
2. Create a new free atSign (e.g. `@myservices`)
3. Download its `.atKeys` file → place in `~/.atsign/keys/`

### Step 2 — Add credentials to `.env`

**Home Automation server:**
```env
SERVICES_AT_SIGN=@myservices
SERVICES_KEY_FILE=@myservices_key.atKeys
HA_BASE_URL=http://homeassistant.local:8123
HA_TOKEN=eyJ...long_lived_access_token...
```

**Database server:**
```env
SERVICES_AT_SIGN=@myservices
SERVICES_KEY_FILE=@myservices_key.atKeys
DB_PATH=/data/pembrook.db   # path inside the container
```

> Get a Home Assistant long-lived access token: **HA → Profile → Long-Lived Access Tokens → Create Token**

### Step 3 — Allow the services atSign to talk to the agent

If `@myservices` is already in `ALLOWED_USERS` (because you added it for bridges), **nothing more is needed**.

If not, add it:
```env
ALLOWED_USERS=@myowner,@myservices
```

### Step 4 — Uncomment and start the MCP service

Edit `docker-compose.yml`: find the commented-out `mcp_home:`, `mcp_database:`, or `mcp_browser:` service block and uncomment it.

Then:
```bash
docker compose up -d mcp_home
# or:
docker compose up -d mcp_database
# or:
docker compose up -d mcp_browser
```

### Step 5 — Verify

```bash
docker compose logs -f mcp_home
```

You should see:
```
[INFO] MCP  — Connected as @myservices on namespace pembrook
[INFO] MCP  — Waiting for commands from @myagent
```

---

## 11. Enable Bridges (Optional)

Bridges relay messages from external platforms (WhatsApp, Telegram, Discord, Slack) to the agent.  
All bridges share the services atSign (`@myservices` in these examples) together with any MCP servers you have enabled.

> **Important:** Each bridge process reads the agent atSign from the `AGENT_AT_SIGN` environment variable.  
> This is set automatically in `docker-compose.yml` from your `.env` file.  
> If `AGENT_AT_SIGN` is missing, bridges fall back to the literal placeholder `@agent` and log a warning.

### Step 1 — Get platform credentials

| Bridge | What you need | Where to get it |
|---|---|---|
| WhatsApp | Access token, Phone number ID, App secret | [Meta for Developers](https://developers.facebook.com/apps/) |
| Telegram | Bot token | [@BotFather](https://t.me/BotFather) on Telegram |
| Discord | Bot token | [Discord Developer Portal](https://discord.com/developers/applications) |
| Slack | Signing secret, Bot token | [Slack API](https://api.slack.com/apps) |

### Step 2 — Add credentials to `.env`

Uncomment and fill in the relevant section of `.env`:

```env
# WhatsApp
WHATSAPP_ACCESS_TOKEN=EAAxxxxxxx
WHATSAPP_PHONE_NUMBER_ID=1234567890
WHATSAPP_WEBHOOK_VERIFY_TOKEN=my_secret_token
WHATSAPP_APP_SECRET=abc123

# Telegram
TELEGRAM_BOT_TOKEN=123456789:AAxxxxxxx
```

### Step 3 — Uncomment the bridge service in `docker-compose.yml`

Edit `docker-compose.yml` and uncomment the `bridge_whatsapp:` (or other bridge) block.

### Step 4 — Restart

```bash
docker compose up -d --build
```

### Step 5 — Expose webhook endpoints (WhatsApp / Slack)

WhatsApp and Slack require a public HTTPS URL for webhooks.  
Use a reverse proxy (nginx, Caddy) or a tunnel service:

```bash
# Quick test with ngrok:
ngrok http 8080   # for WhatsApp bridge
```

Configure the webhook URL in the Meta / Slack developer console.

---

## 12. Allow Additional Users

By default, only `@myowner` (and `@myservices` if configured) can send commands to the agent.  
To allow other atSigns, update the `settings.allowed_users` AtKey on the agent:

```bash
cd agent
dart run bin/init_config.dart \
  --atsign @myagent \
  --key-file ~/.atsign/keys/@myagent_key.atKeys \
  --owner @myowner \
  --allowed-users @myowner,@myservices,@alice,@bob
```

The agent picks up the change within **5 minutes** (allowList is refreshed on a timer).  
No restart is required.

### What happens when a new user first connects?

1. The atSign must be in the allowList to pass the Gateway check
2. The PolicyEngine will apply the **default policy** (deny if no identity rule matches)
3. Create a policy rule for the new user in the Flutter app: **Policy** → **Add Rule** → set identity = `@alice`, action = `chat_command`, effect = `allow`
4. The new user can now send commands

---

## 13. Managing Policies

Pembrook has a built-in policy engine that controls who can do what.  
Policies are stored as AtKeys on the agent's atServer and managed from the Flutter app.

**Policy** screen in the app:

- **Policy List** — view all rules in priority order
- **Add Rule** — choose effect (allow/deny), action, and optionally restrict by atSign, time window, or keywords
- **Edit / Delete** — modify existing rules

Rules are evaluated top-down; the first matching rule wins.  
A default "deny all" rule sits at the bottom.

### Useful policy patterns

| Pattern | Settings |
|---|---|
| Allow `@alice` for chat only | identity=`@alice`, action=`chat_command`, effect=allow |
| Allow `@team_bridges` for bridge messages | identity=`@team_bridges`, action=`chat_command`, effect=allow |
| Deny skill execution after 22:00 | action=`skill_run`, time window=`07:00–22:00`, effect=deny (outside window) |
| Allow `@alice` but block certain keywords | identity=`@alice`, keyword blocklist=`delete,drop,format`, effect=deny |

---

## 14. Troubleshooting

### Agent fails to start — "container pembrook-ollama is unhealthy"

The agent no longer waits for Ollama to be healthy before starting — it retries the Ollama connection at request time. If you see this error it means you're on an older version of `docker-compose.yml`.

If Ollama itself won't start at all:

```bash
# Check what Ollama is actually doing:
docker compose logs ollama

# Manually test if the port is open:
bash -c 'echo > /dev/tcp/localhost/11434' && echo "up" || echo "not ready"

# Force a fresh start:
docker compose down && docker compose up -d
```

If Ollama consistently fails, check available RAM — `qwen2.5:7b` (7B) needs ~6 GB free.  
Switch to a smaller model: edit `OLLAMA_MODEL=qwen2.5:3b` in `.env`.

### Agent fails to start — "AllowList is empty"

The agent couldn't read the `settings.allowed_users` AtKey and no `ALLOWED_USERS` env var was set.  
Fix: run the setup wizard again, or add `ALLOWED_USERS=@myowner` to `.env` and restart.

### Agent fails to authenticate — "InvalidAtKeyException"

The `.atKeys` file path is wrong or the file is corrupted.  
Check:
```bash
cat ~/.atsign/keys/@myagent_key.atKeys | head -5   # should be valid JSON
ls -la ~/.atsign/keys/                             # verify files exist and are readable
```

### "sharedWith must be different from sharedBy" crash

This means you accidentally set the same atSign for both the agent and the owner (or bridge).  
Each role **must** be a different atSign. Re-run `setup.sh` with distinct atSigns.

### App shows "Agent offline"

1. Check agent container is running: `docker compose ps`
2. Check agent logs: `docker compose logs --tail=50 agent`
3. Ensure the app's **Settings → Agent atSign** matches `AGENT_AT_SIGN` in `.env`
4. Both the app device and the agent server need internet access to reach the atPlatform root server (`root.atsign.org:64`)

### Ollama returns 404 or times out

**Using host Ollama (default):** make sure Ollama is running and reachable:
```bash
curl http://localhost:11434/api/tags          # from host — should return JSON
curl http://host.docker.internal:11434/api/tags  # from inside a container
```
On Linux, if the second command fails, Ollama is only listening on loopback:
```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

**Using bundled Ollama:** the model must be pulled first:
```bash
docker compose --profile bundled-ollama run --rm ollama ollama pull qwen2.5:7b
```
Check available models:
```bash
docker compose exec ollama ollama list    # bundled
ollama list                               # host
```

### AllowList change not taking effect

The agent refreshes the allowList every **5 minutes**.  
If you need an immediate update, restart the agent:
```bash
docker compose restart agent
```

### Enable verbose logging

The agent uses the `logging` package.  
Set `Logger.root.level = Level.ALL` in `agent/bin/main.dart` temporarily, or add `--verbose` to the agent command in `docker-compose.yml`.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                 atPlatform (cloud relay)              │
│         encrypted, end-to-end, zero-knowledge        │
└──────────┬───────────────────────────┬──────────────┘
           │ outbound only             │ outbound only
    ┌──────▼──────┐             ┌──────▼──────┐
    │  Flutter app │             │  Bridges +  │
    │  @owner      │             │  MCP servers│
    │  (your phone)│             │  @services  │
    └─────────────┘             │ (WhatsApp / │
                                │  Telegram / │
                                │  Discord /  │
                                │  Slack /    │
                                │  @mcp_home /│
                                │  @mcp_db)   │
                                └──────┬──────┘
                                       │
                                ┌──────▼──────────────────────────────┐
                                │         Pembrook Agent               │
                                │         @agent                       │
                                │  ┌──────────┐  ┌──────────────────┐ │
                                │  │ Gateway  │  │   Orchestrator   │ │
                                │  │ (AtRpc)  │→ │  LLM + Skills +  │ │
                                │  │ allowList│  │  Memory + Policy │ │
                                │  └──────────┘  └──────────────────┘ │
                                │              ┌──────────┐            │
                                │              │  Ollama  │ (local LLM)│
                                │              └──────────┘            │
                                └─────────────────────────────────────┘
```

- **Zero inbound ports** on the agent — all communication is outbound atPlatform notification subscription
- **End-to-end encrypted** — atPlatform root server never sees message content
- **Data sovereignty** — all conversation history, policy, and audit logs stored in your own atServer namespace

---

## File Layout Reference

```
pembrook/
├── agent/                  ← Dart agent daemon
│   ├── bin/
│   │   ├── main.dart       ← entry point
│   │   └── init_config.dart← first-run AtKey writer
│   └── lib/
│       ├── gateway/        ← AtRpc server + allowList
│       ├── core/           ← Orchestrator, PolicyEngine, LlmRouter
│       └── services/       ← Audit, Memory, Notification, ...
├── app/                    ← Flutter client app (@owner)
├── bridge/
│   ├── whatsapp/           ← WhatsApp Cloud API bridge
│   ├── telegram/           ← Telegram Bot API bridge
│   ├── discord/            ← Discord Gateway bridge
│   └── slack/              ← Slack Events API bridge
├── skills/                 ← Skill runners (web_search, email, calendar)
├── mcp_servers/            ← MCP server integrations
├── keys/                   ← not used; .atKeys files live in ~/.atsign/keys/
├── scripts/
│   └── setup.sh            ← interactive setup wizard
├── docker-compose.yml      ← CPU mode (works everywhere)
├── docker-compose.gpu.yml  ← GPU override (Linux + NVIDIA only)
├── .env.example
└── GETTING_STARTED.md      ← this file
```
