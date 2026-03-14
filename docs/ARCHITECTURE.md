# SafeClaw Architecture Reference

This document covers the internal design, data-flow, component contracts, and implementation decisions for SafeClaw.  
For setup instructions see [GETTING_STARTED.md](../GETTING_STARTED.md).

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [atPlatform Concepts](#2-atplatform-concepts)
3. [Agent Daemon](#3-agent-daemon)
4. [Flutter App](#4-flutter-app)
5. [Chat History](#5-chat-history)
6. [Skills System](#6-skills-system)
7. [MCP Servers](#7-mcp-servers)
8. [Messaging Bridges](#8-messaging-bridges)
9. [Policy Engine](#9-policy-engine)
10. [Key Design Decisions & Bug History](#10-key-design-decisions--bug-history)

---

## 1. System Overview

```
┌────────────────────────────────────────────────────────────────────┐
│                     atPlatform Cloud Relay                         │
│            end-to-end encrypted, zero-knowledge relay              │
└──────────┬──────────────────────────┬───────────────────┬─────────┘
           │                          │                   │
    ┌──────▼──────┐            ┌──────▼──────┐    ┌──────▼──────┐
    │ Flutter App  │            │   Bridges   │    │ MCP Servers │
    │  @owner      │            │  @bridges   │    │  @mcp_*     │
    └──────┬───────┘            └──────┬──────┘    └──────┬──────┘
           │  AtRpc (encrypted)        │  AtRpc           │  AtRpc
           └──────────────────────────┴──────────────────┘
                                       │
                        ┌──────────────▼─────────────────────────┐
                        │           Agent Daemon                  │
                        │             @agent                      │
                        │                                         │
                        │  Gateway (AtRpc server)                 │
                        │    │ allowList check                    │
                        │    │ _sys.* system commands             │
                        │    ▼                                    │
                        │  PolicyEngine                           │
                        │    │ allow/deny/audit                   │
                        │    ▼                                    │
                        │  Orchestrator                           │
                        │    ├── LlmRouter → Ollama               │
                        │    ├── MemoryService (AtKeys on @agent) │
                        │    ├── AuditService (AtKeys on @owner)  │
                        │    ├── SkillRegistry → @skill_*         │
                        │    └── SecureMcpClient → @mcp_*         │
                        └─────────────────────────────────────────┘
```

All inter-component communication is:
- **outbound-only** from every process (no open inbound ports anywhere)
- **end-to-end encrypted** by the atPlatform (relay never sees plaintext)
- **cryptographically authenticated** via atSign PKAM

---

## 2. atPlatform Concepts

### AtKeys

AtKeys are the fundamental data unit. Key format: `@recipient:keyname.namespace@sender`

| atSign role | Purpose |
|---|---|
| `@agent` | The agent daemon — all other services communicate *with* this atSign |
| `@owner` | Your Flutter app / CLI — sends commands *to* `@agent` |
| `@services` | **All** bridges + **all** MCP servers share this — they send/receive to/from `@agent` |

> **Maximum 3 atSigns** are ever needed, no matter how many bridges or MCP servers are enabled.  
> `@agent` cannot be reused for any other role: the atPlatform forbids a notification whose sender and recipient are the same atSign.

**Self key** (only sender can read): `keyname.safeclaw@agent`  
**Shared key** (recipient can read): `@owner:keyname.safeclaw@agent`

> **Important:** `@agent:key@owner` (shared, sender=owner) is a *completely different key* from `key@agent` (self, sender=agent).  
> This was the root cause of the skills mismatch — see §10.

### AtRpc

AtRpc is SafeClaw's inter-process communication layer built on top of AtKeys.

- **Caller** writes a request AtKey: `@callee:rpc_req.uuid.safeclaw@caller`
- **Server** processes it, writes a response AtKey: `@caller:rpc_res.uuid.safeclaw@callee`
- **Caller** subscribes to notifications from its own atServer and reads the response

This gives us:
- Zero open ports (pure subscription to own atServer)
- E2E encryption on all RPC payloads
- Natural allowList enforcement (atServer refuses keys from unknown senders)

---

## 3. Agent Daemon

**Entry point:** `agent/bin/main.dart`  
**Runs as:** Docker container (image built by `Dockerfile.agent`)

### Startup sequence

```
1. CLIBase.fromCommandLineArgs()    — parse flags, authenticate atSign
2. Logger.root.level = Level.INFO  — restore log level (CLIBase sets SHOUT)
3. SkillRegistry.create()          — load persisted skills from self-keys
4. PolicyEngine / AuditService / MemoryService / LlmRouter / Orchestrator
5. Gateway.start()                 — AtRpc server, begins accepting requests
6. Heartbeat.start()               — periodic health ping
```

### Gateway (`agent/lib/gateway/`)

`Gateway` is the main AtRpc server. On each incoming request it:

1. Checks the sender atSign is in `allowList` (reject otherwise)
2. Dispatches to `GatewayCallbacks.handleRequest()`

`GatewayCallbacks` first checks whether the command starts with `_sys.`:
- `_sys.*` → `_handleSysCommand()` (internal management, never reaches the LLM)
- anything else → `PolicyEngine.check()` → `Orchestrator.process()`

### System commands (`_sys.*`)

| Command | Handler | Description |
|---|---|---|
| `_sys.skill.install` | `_sysSkillInstall()` | Register or update a skill in the live `SkillRegistry` |
| `_sys.skill.uninstall` | `_sysSkillUninstall()` | Remove a skill from the live `SkillRegistry` |
| `_sys.skill.list` | `_sysSkillList()` | Return JSON array of all registered skills |

These commands are only accepted from atSigns in `allowList` — the policy engine is bypassed but the gateway's allowList check still applies.

### SkillRegistry (`agent/lib/skills/registry.dart`)

Stores `SkillMetadata` instances keyed by `skillId`.  
Skills are persisted as self-keys on `@agent`: `skill_meta.<id>.safeclaw@agent`

The registry is injected into `GatewayCallbacks` so `_sys.skill.install` can register skills in the live instance without a restart.

---

## 4. Flutter App

**Entry point:** `app/lib/main.dart`  
**Platform:** macOS, iOS, Windows, Linux, Android, Web

### Routing (`go_router`)

| Path | Widget | Purpose |
|---|---|---|
| `/` *(shell)* | `MainShell` | Bottom nav, shared providers |
| `/chat` | `ChatScreen` | Main chat + conversation management |
| `/history` | `ChatHistoryScreen` | Browse/load/delete past conversations |
| `/skills` | `SkillsScreen` | Manage registered skills |
| `/audit` | `AuditScreen` | View immutable audit log |
| `/hitl` | `HitlScreen` | Approve/deny pending HITL actions |
| `/policy` | `PolicyScreen` | Edit YAML policy rules |
| `/settings` | `SettingsScreen` | LLM + atSign configuration |

### Provider tree

```
MultiProvider
 ├── AtClientProvider        — authenticated atClient singleton
 ├── RpcService              — AtRpc client wrapper
 ├── ConversationStore       — local chat history (SharedPreferences)
 └── DataService             — AtKey CRUD helpers
```

---

## 5. Chat History

### Problem (fixed)

The original `ChatScreen` generated a single `_conversationId` UUID in `initState()` and never changed it.  
`_newConversation()` cleared the message list but kept the same UUID, so the agent's memory indexed old and new messages under the same conversation — effectively merging all chat sessions.

### Solution

1. **Per-conversation UUID** — `_newConversation()` now calls `_uuid.v4()` to generate a fresh `_conversationId`
2. **`ConversationStore`** — saves/loads conversation summaries to `SharedPreferences` as JSON
3. **`ChatHistoryScreen`** — lets the user browse, restore, and delete past sessions

### Data model (`app/lib/services/data_service.dart`)

```dart
class StoredMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
}

class ConversationSummary {
  final String id;          // UUID4
  final String title;       // first user message, truncated
  final DateTime createdAt;
  final List<StoredMessage> messages;
}

class ConversationStore extends ChangeNotifier {
  // Backed by SharedPreferences key 'conversations' as JSON list
  static const int maxConversations = 100;  // oldest pruned on overflow

  Future<void> load();                        // populates _conversations
  Future<void> save(ConversationSummary s);   // no-op if no user messages
  Future<void> delete(String id);
  ConversationSummary? get(String id);
  List<ConversationSummary> get all;          // newest first
}
```

### Chat history UX flow

```
ChatScreen (active session)
  │
  ├─ "🕐" button → _openHistory()
  │     └─ context.push('/history')
  │           → ChatHistoryScreen
  │               │ user taps a past conversation
  │               └─ context.pop(ConversationSummary)
  │     └─ receives result → _loadConversation(summary)
  │
  └─ "➕" button → _newConversation()
        └─ saves current session
        └─ _conversationId = _uuid.v4()
        └─ clears message list
```

---

## 6. Skills System

### Sandbox execution model

Each skill is a **Docker container** spawned per invocation by `SandboxManager`.  
The image name is derived from the Skill ID registered in the app:

```
safeclaw-skill-<skillId>:latest
```

Security constraints applied to every container run:

| Flag | Value | Purpose |
|---|---|---|
| `--rm` | — | Remove container on exit (no persistent state) |
| `--network=none` | — | Zero network access inside the sandbox |
| `--memory` | `256m` | Hard memory cap |
| `--cpus` | `0.5` | Hard CPU cap |
| `--read-only` | — | Read-only root filesystem |
| `--cap-drop` | `ALL` | Drop all Linux capabilities |
| `--security-opt` | `no-new-privileges` | Prevent privilege escalation |

> **Network-dependent skills** (email, calendar, web_search) require a custom sandbox profile with egress allow-listing — the default `--network=none` will block their outbound connections.

#### stdin/stdout JSON protocol

```
SandboxManager                              Skill container (stdin/stdout)
      │                                               │
      │  {"command":"run","payload":{...},"requestId":"<id>"}
      │──────────────────────────────────────────────>│
      │                                               │ executes action
      │  {"status":"ok","result":{...},"requestId":"<id>"}
      │<──────────────────────────────────────────────│
```

On error the container writes `{"status":"error","error":"<message>","requestId":"<id>"}` to stdout and exits non-zero.

#### Built-in skills

| Skill ID | Directory | Key actions |
|---|---|---|
| `email` | `skills/email/` | `send_email`, `list_inbox`, `read_email`, `delete_email` |
| `calendar` | `skills/calendar/` | CalDAV read/create/update |
| `web_search` | `skills/web_search/` | `search.query`, `search.get_page` |

#### Building a skill image

```bash
# From repo root — repeat per skill
docker build -t safeclaw-skill-email:latest -f skills/email/Dockerfile .
```

The agent accesses Docker via `/var/run/docker.sock` (mounted in `docker-compose.yml`).  
The image must be present on the same Docker host as the agent container.

---

### Problem (fixed) — AtKey namespace mismatch

The Flutter app stored skills using the AtKey `@agent:skill_meta.<id>.safeclaw@owner`  
(a **shared** key — sender is `@owner`, recipient is `@agent`).

The agent's `SkillRegistry` looked for `skill_meta.<id>.safeclaw@agent`  
(a **self** key — owner is `@agent`).

These are cryptographically distinct keys. The agent never saw skills registered from the app.

### Solution — RPC-based sync

Instead of relying on a common AtKey namespace, the app now explicitly tells the agent about skills via `_sys.skill.*` RPC commands over the existing secure channel.

```
App (SkillsScreen)                     Agent (GatewayCallbacks)
        │                                       │
        │  _sys.skill.install { skillId, ... }  │
        │──────────────────────────────────────>│
        │                                       ├── SkillRegistry.installSkill(meta)
        │                                       │    └── writes self-key on @agent
        │  { success: true }                    │
        │<──────────────────────────────────────│
```

### Skills screen triggers for RPC sync

| User action | RPC command sent |
|---|---|
| Save new skill | `_sys.skill.install` |
| Edit existing skill | `_sys.skill.install` (upsert) |
| Toggle enable/disable | `_sys.skill.install` with updated `enabled` field |
| Delete skill | `_sys.skill.uninstall` |

### SkillMetadata mapping

The app's `SkillData` (UI model) is mapped to `SkillMetadata` (agent model) in `_sysSkillInstall()`:

| SkillData field | SkillMetadata field | Notes |
|---|---|---|
| `skillId` | `skillId` | Direct |
| `skillAtSign` | `skillAtSign` | Direct |
| `description` | `ownerPolicyOverrides['description']` | |
| `version` | `version` | |
| `enabled` | `ownerPolicyOverrides['enabled']` | Also sets `trustScore` |
| *(derived)* | `developerAtSign` | Set to `fromAtSign` (the owner's atSign) |
| *(derived)* | `signatureHash` | `app-registered-<uuid>` (placeholder) |
| *(derived)* | `installedAt` | `DateTime.now().toUtc()` |

---

## 7. MCP Servers

MCP (Model Context Protocol) servers run as separate Dart processes, each with their own atSign.  
They expose tools the agent can call via `SecureMcpClient`.

### Communication pattern

```
Agent (@agent)                         MCP Server (@mcp_home)
       │                                       │
       │  AtRpc: { tool: "turn_on", ... }      │
       │──────────────────────────────────────>│
       │                                       ├── calls Home Assistant REST API
       │  { result: "ok" }                     │
       │<──────────────────────────────────────│
```

`SecureMcpClient` (`agent/lib/mcp/secure_mcp_client.dart`) wraps the AtRpc call with a `_waitForResponse()` subscription so it behaves like a synchronous function call from the orchestrator's perspective.

### Logging fix

`CLIBase.fromCommandLineArgs()` sets `Logger.root.level = Level.SHOUT` internally.  
Every MCP server (and every bridge) must reset this after calling `fromCommandLineArgs()`:

```dart
final cli = await CLIBase.fromCommandLineArgs(args);
Logger.root.level = Level.INFO;  // ← required, or all logs are silenced
```

### Available servers

Both services use `SERVICES_AT_SIGN` / `SERVICES_KEY_FILE` — the same third atSign shared with bridges. No dedicated atSign per MCP server is needed.

| Directory | Key env vars |
|---|---|
| `mcp_servers/home/` | `HA_BASE_URL`, `HA_TOKEN` |
| `mcp_servers/database/` | `DB_PATH` |

Both are defined as commented-out service blocks in `docker-compose.yml`.  
Uncomment the relevant service and set the corresponding env vars in `.env` to enable.

---

## 8. Messaging Bridges

Each bridge (WhatsApp, Telegram, Discord, Slack) is a Dart process that:
1. Listens for messages from its platform (poll or webhook)
2. Formats them as AtRpc requests
3. Sends them to `@agent` (value of `AGENT_AT_SIGN`)
4. Returns the agent's response to the platform

### AGENT_AT_SIGN fix

All bridges previously had:
```dart
const _agentAtSign = '@agent';  // ← was a literal placeholder
```

This has been replaced with:
```dart
String _agentAtSign = '@agent';  // overridden at startup
// In main(), after CLIBase:
_agentAtSign = Platform.environment['AGENT_AT_SIGN'] ?? '@agent';
```

`docker-compose.yml` passes `AGENT_AT_SIGN` from `.env` to each bridge container:
```yaml
environment:
  AGENT_AT_SIGN: "${AGENT_AT_SIGN:-@agent}"
```

If `AGENT_AT_SIGN` is not set, the bridge logs a warning and falls back to `@agent` (which will fail unless you actually have an atSign called `@agent`).

### Bridge process locations

| Platform | Directory | Key env vars |
|---|---|---|
| WhatsApp | `bridge/whatsapp/` | `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_APP_SECRET` |
| Telegram | `bridge/telegram/` | `TELEGRAM_BOT_TOKEN` |
| Discord | `bridge/discord/` | `DISCORD_TOKEN` |
| Slack | `bridge/slack/` | `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET` |

WhatsApp and Slack require a public HTTPS webhook endpoint — use a reverse proxy or a tunnel service for local development.

---

## 9. Policy Engine

Every non-`_sys.*` request from the Gateway is evaluated by `PolicyEngine` before reaching the Orchestrator.

Rules are stored as AtKeys on `@agent`'s atServer and loaded at startup (and refreshed hourly).  
The Flutter app's **Policy** screen reads and writes these rules via `DataService`.

### Rule evaluation

Rules are evaluated top-down by priority. The first matching rule wins.  
A built-in **deny-all** rule sits at the bottom.

### Rule fields

| Field | Type | Notes |
|---|---|---|
| `identity` | atSign glob | `@alice`, `@team_*`, or `*` |
| `action` | string | `chat_command`, `skill_run`, `memory_read`, etc. |
| `effect` | `allow`/`deny` | Action on match |
| `timeWindow` | `"HH:MM–HH:MM"` | Optional; evaluated in agent's system timezone |
| `keywords` | string list | Optional block list applied to message body |
| `priority` | int | Lower numbers evaluated first |

---

## 10. Key Design Decisions & Bug History

### Why RPC for skill sync instead of a shared AtKey?

**Rejected alternative:** Have the app write `skill_meta.<id>.safeclaw@agent` (self-key on `@agent`).  
**Problem:** The atPlatform `sharedWith` restriction — a key `@agent:x@owner` is owned by `@owner` and readable by `@agent`; but a self-key `x@agent` can only be written by `@agent`. The app authenticates as `@owner`, not `@agent`, so it cannot write to `@agent`'s self-key namespace.

**Solution chosen:** App sends `_sys.skill.install` RPC to the agent. The agent (running as `@agent`) then writes its own self-key. Clean separation of authority.

### Why SharedPreferences for chat history instead of AtKeys?

**AtKeys** would survive device reinstalls and be accessible from multiple devices.  
**SharedPreferences** is simpler, faster (no network round-trip), and doesn't put potentially sensitive conversation content on the atServer.

Future enhancement: opt-in sync to AtKeys for multi-device history.

### CLIBase Logger.root.level = Level.SHOUT

`at_cli_commons` v3.x resets `Logger.root.level` to `Level.SHOUT` at the end of `fromCommandLineArgs()`.  
This silences all `INFO`, `WARNING`, `SEVERE` log output, making debugging very difficult.  
**Workaround:** reset the level immediately after the `await CLIBase.fromCommandLineArgs(args)` call in every executable (`main.dart` in each service).

### Bridge `const _agentAtSign = '@agent'`

This was a copy-paste artifact from early development where the agent atSign was literally `@agent`.  
Making it a `const` meant it could never be changed at runtime from environment.  
**Fix:** changed to `String` and read from `Platform.environment['AGENT_AT_SIGN']`.

### Chat `_conversationId` never changed

`initState()` called `_uuid.v4()` once. `_newConversation()` cleared `_messages` but left `_conversationId` unchanged.  
The agent's memory stored and retrieved all context under one `conversationId`, so new conversations inherited all old context.  
**Fix:** `_newConversation()` calls `_uuid.v4()` to produce a fresh ID before clearing messages, and also calls `_saveCurrentConversation()` to persist the outgoing session.
