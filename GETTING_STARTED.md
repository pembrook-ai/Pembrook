# Getting Started with SafeClaw

SafeClaw is a privacy-first personal AI agent that runs entirely on infrastructure you control.  
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
8. [Enable Bridges (Optional)](#8-enable-bridges-optional)
9. [Allow Additional Users](#9-allow-additional-users)
10. [Managing Policies](#10-managing-policies)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Dart SDK | ≥ 3.6 | [dart.dev/get-dart](https://dart.dev/get-dart) |
| Docker + Compose | Docker Desktop 4.x or Engine + Compose plugin v2 | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| Flutter SDK | ≥ 3.29 | [flutter.dev/install](https://flutter.dev/install) (for building the app) |
| Ollama | any | Bundled in `docker-compose.yml` — no separate install needed |
| atSigns | 2–3 | Free at [my.atsign.com](https://my.atsign.com/dashboard) |

---

## 2. Register your atSigns

SafeClaw uses [atSigns](https://atsign.com) as cryptographic identities.  
You need **at minimum 2 atSigns**, and **3 if you want messaging bridges**.

### Why multiple atSigns?

The atPlatform's `sharedWith` notation (`@bob:key@alice`) requires the **sender and recipient to be different atSigns**.  
A single atSign cannot send a notification to itself — so the agent and the entity talking to the agent must be different identities.

| atSign role | Purpose | Minimum |
|---|---|---|
| `@agent` | The daemon process on your server | **Required** |
| `@owner` | Your personal identity — Flutter app, CLI | **Required** |
| `@bridges` | Shared by all 4 bridge processes (WhatsApp / Telegram / Discord / Slack) | Only if using bridges |

> **Good news:** all four bridge processes can share ONE atSign — routing is UUID-based so there is no cross-contamination.  
> A single `@bridges` atSign is all you need, even if you run all four bridges simultaneously.

### Steps

1. Go to [my.atsign.com/dashboard](https://my.atsign.com/dashboard)
2. Click **Create a free atSign** for each identity you need
3. On the dashboard, click the atSign → **Download Keys** → save the `.atKeys` file

You will have files like:
```
@myagent_key.atKeys
@myowner_key.atKeys
@mybridges_key.atKeys   ← only if you want bridges
```

Copy these into the `keys/` directory in the project root:
```
safeClaw/
  keys/
    @myagent_key.atKeys
    @myowner_key.atKeys
    @mybridges_key.atKeys
```

> **Security:** The `keys/` directory is in `.gitignore` and is never committed.  
> It is mounted **read-only** into Docker containers.

---

## 3. Clone & Install

```bash
git clone https://github.com/cconstab/safeClaw.git
cd safeClaw
mkdir -p keys
# Place your .atKeys files in keys/
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
| Agent .atKeys file path | `./keys/@myagent_key.atKeys` |
| Bridges atSign (optional) | `@mybridges` |
| Bridges .atKeys file path | `./keys/@mybridges_key.atKeys` |
| Ollama model | `llama3.2` |
| Extra allowed atSigns | *(leave blank)* |

The wizard will:
1. Validate all prerequisites
2. Write `.env` in the project root
3. Run `dart run agent/bin/init_config.dart` to write settings AtKeys to `@myagent`'s atServer

### Non-interactive mode (CI / server setup)

```bash
AGENT_AT_SIGN=@myagent \
OWNER_AT_SIGN=@myowner \
AGENT_KEYS_PATH=./keys/@myagent_key.atKeys \
BRIDGES_AT_SIGN=@mybridges \
BRIDGES_KEYS_PATH=./keys/@mybridges_key.atKeys \
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
  --key-file ../keys/@myagent_key.atKeys \
  --owner @myowner \
  --bridges-atsign @mybridges \
  --ollama-model llama3.2 \
  --verbose
```

---

## 5. Start the Backend

### First run — pull the Ollama model (this downloads several GB):

```bash
docker compose run --rm ollama ollama pull llama3.2
```

> Use a quantised model if RAM is limited:  
> `ollama pull llama3.2:1b` (1 billion params, ~1 GB)  
> `ollama pull phi4-mini` (3.8 billion params, ~2.5 GB)

### Start all services:

```bash
docker compose up -d
```

This starts:
- **ollama** — local LLM server (no internet required for inference)
- **agent** — SafeClaw daemon (outbound only to atPlatform, no open ports)

### Watch the logs:

```bash
docker compose logs -f agent
```

You should see output like:
```
[INFO] Gateway  — AllowList refreshed: [@myowner, @mybridges]
[INFO] Gateway  — Gateway started on @myagent namespace=safeclaw...
[INFO] Heartbeat — SafeClaw agent is running.
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
  --key-file ../keys/@myagent_key.atKeys \
  --owner @myowner \
  --verbose
```

If it exits cleanly, authentication and AtKey writing both work.

---

## 8. Enable Bridges (Optional)

Bridges relay messages from external platforms (WhatsApp, Telegram, Discord, Slack) to the agent.  
All bridges share the `@bridges` atSign.

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

## 9. Allow Additional Users

By default, only `@myowner` (and `@mybridges` if configured) can send commands to the agent.  
To allow other atSigns, update the `settings.allowed_users` AtKey on the agent:

```bash
cd agent
dart run bin/init_config.dart \
  --atsign @myagent \
  --key-file ../keys/@myagent_key.atKeys \
  --owner @myowner \
  --allowed-users @myowner,@mybridges,@alice,@bob
```

The agent picks up the change within **5 minutes** (allowList is refreshed on a timer).  
No restart is required.

### What happens when a new user first connects?

1. The atSign must be in the allowList to pass the Gateway check
2. The PolicyEngine will apply the **default policy** (deny if no identity rule matches)
3. Create a policy rule for the new user in the Flutter app: **Policy** → **Add Rule** → set identity = `@alice`, action = `chat_command`, effect = `allow`
4. The new user can now send commands

---

## 10. Managing Policies

SafeClaw has a built-in policy engine that controls who can do what.  
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

## 11. Troubleshooting

### Agent fails to start — "AllowList is empty"

The agent couldn't read the `settings.allowed_users` AtKey and no `ALLOWED_USERS` env var was set.  
Fix: run the setup wizard again, or add `ALLOWED_USERS=@myowner` to `.env` and restart.

### Agent fails to authenticate — "InvalidAtKeyException"

The `.atKeys` file path is wrong or the file is corrupted.  
Check:
```bash
cat keys/@myagent_key.atKeys | head -5    # should be valid JSON
ls -la keys/                              # verify file exists and is readable
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

The Ollama service needs the model to be pulled first:
```bash
docker compose run --rm ollama ollama pull llama3.2
```

Check available models:
```bash
docker compose exec ollama ollama list
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
    │  Flutter app │             │    Bridges   │
    │  @owner      │             │  @bridges    │
    │  (your phone)│             │ (WhatsApp /  │
    └─────────────┘             │  Telegram /  │
                                │  Discord /   │
                                │  Slack)      │
                                └──────┬───────┘
                                       │
                                ┌──────▼──────────────────────────────┐
                                │         SafeClaw Agent               │
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
safeClaw/
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
├── keys/                   ← .atKeys files (gitignored)
├── scripts/
│   └── setup.sh            ← interactive setup wizard
├── docker-compose.yml
├── .env.example
└── GETTING_STARTED.md      ← this file
```
