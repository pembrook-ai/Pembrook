# Pembrook — Implementation Phases

This document is the canonical reference for Pembrook's phased implementation plan.
It records what is **done**, what is a **stub**, and what is **planned** for each phase,
together with the acceptance criteria that close each phase.

---

## Phase 0 — Infrastructure  ✅ Complete

**Goal:** Container environment and project scaffolding so every subsequent phase can be developed and deployed consistently.

### Components

| File | Status | Notes |
|------|--------|-------|
| `docker-compose.yml` | ✅ Done | Wires `agent`, `ollama` services; mounts `~/.atsign/` for keys |
| `Dockerfile.agent` | ✅ Done | Multi-stage Dart build; runs `pembrook_agent` binary |
| `agent/pubspec.yaml` | ✅ Done | All Phase 1–2 deps declared; `dart pub get` resolves cleanly |
| `app/pubspec.yaml` | ✅ Done | Flutter app deps; `flutter pub get` resolves cleanly |

### Acceptance Criteria

- [ ] `docker compose build` succeeds with no errors
- [ ] `dart pub get` in `agent/` produces a clean lock file
- [ ] `flutter pub get` in `app/` produces a clean lock file

---

## Phase 1 — Foundation  ✅ Complete

**Goal:** End-to-end privacy-first AI agent: encrypted transport, local LLM, policy enforcement, human-in-the-loop, persistent memory, and Flutter UI.

### Architecture layers

```
Flutter App  ──atNotification──►  Gateway  ──►  Orchestrator
                                                    │
                         ┌──────────────────────────┼──────────────────────┐
                         ▼                          ▼                      ▼
                   PolicyEngine              LlmRouter               MemoryService
                         │                  (Ollama / ext)                 │
                   HitlManager                 Sanitizer              AuditService
```

### Components

#### Agent — Core

| File | Status | Notes |
|------|--------|-------|
| `agent/bin/main.dart` | ✅ Done | `CLIBase.fromCommandLineArgs`; wires all services; injects `--storage-dir` / `--namespace` |
| `agent/lib/gateway/gateway.dart` | ✅ Done | `AtRpc` server; default allow-list; rate limiting |
| `agent/lib/gateway/gateway_callbacks.dart` | ✅ Done | `handleRequest()`; policy + HITL check; streams response |
| `agent/lib/core/orchestrator.dart` | ✅ Done | Intent classification → route → memory save → audit |
| `agent/lib/core/policy_engine.dart` | ✅ Done | Identity check; dynamic policy AtKey load (5-min cache); HITL escalation list |
| `agent/lib/core/hitl_manager.dart` | ✅ Done | Notify owner → wait → timeout = deny (fail-closed); TTL 5 min |
| `agent/lib/services/llm_router.dart` | ✅ Done | Ollama routing; privacy score threshold; external LLM (OpenAI / Claude); API key from encrypted AtKey |
| `agent/lib/services/sanitizer.dart` | ✅ Done | PII scrubbing before any external LLM call |
| `agent/lib/services/at_platform_service.dart` | ✅ Done | CRUD helpers; distributed mutex via AtKey TTL |

#### Agent — Services (Phase 1 baseline)

| File | Status | Notes |
|------|--------|-------|
| `agent/lib/services/memory_service.dart` | ⚠️ Partial | `loadConversation`, `saveExchange`, `loadUserPreferences`, `saveUserPreferences`, `loadSkillState`, `saveSkillState` — complete; **`summarizeOldConversations()` is a TODO stub** |
| `agent/lib/services/audit_service.dart` | ⚠️ Partial | Immutable AtKey write to `@owner` complete; **hash uses `hashCode.toRadixString(16)` not SHA-256** |

#### Agent — Skills / MCP / Automation scaffolding

| File | Status | Notes |
|------|--------|-------|
| `agent/lib/skills/registry.dart` | ✅ Done | Dynamic skill AtKey scan; `SkillMetadata` deserialise |
| `agent/lib/skills/sandbox_manager.dart` | ✅ Done | `Process.start` into isolated subprocess; capability whitelist |
| `agent/lib/skills/skill_runner.dart` | ✅ Done | Invoke → sandbox → result; deny if undeclared capability |
| `agent/lib/mcp/secure_mcp_client.dart` | ✅ Done | `AtRpc` call to `@mcp_*` atSign; capability check; audit |
| `agent/lib/automation/scheduler.dart` | ✅ Done | Cron-style `Schedule`; `TaskScheduler.tick()` |
| `agent/lib/automation/heartbeat.dart` | ✅ Done | `Timer.periodic(60 s)`; writes heartbeat AtKey; calls `scheduler.tick()` |
| `agent/lib/automation/notification_manager.dart` | ✅ Done | Notify owner via `notificationService.notify()` |

#### Agent — Models

| File | Status |
|------|--------|
| `agent/lib/models/policy.dart` | ✅ Done |
| `agent/lib/models/conversation.dart` | ✅ Done |
| `agent/lib/models/audit_entry.dart` | ✅ Done |
| `agent/lib/models/skill_metadata.dart` | ✅ Done |
| `agent/lib/models/task.dart` | ✅ Done |

#### Flutter App — Screens

| File | Status | Notes |
|------|--------|-------|
| `app/lib/auth/auth_screen.dart` | ✅ Done | atSign onboarding; `at_onboarding_flutter` |
| `app/lib/auth/walkthrough.dart` | ✅ Done | First-run walkthrough |
| `app/lib/chat/chat_screen.dart` | ✅ Done | atNotification subscription; streaming chunk reassembly |
| `app/lib/audit/audit_screen.dart` | ✅ Done | Paginated audit log; AtKey scan |
| `app/lib/skills/skills_screen.dart` | ✅ Done | List / enable / disable skills |
| `app/lib/hitl/hitl_screen.dart` | ✅ Done | Pending approval list; approve / deny |
| `app/lib/settings/settings_screen.dart` | ⚠️ Partial | UI complete; **persists to `SharedPreferences` only — not synced to AtKey** |

### Acceptance Criteria

- [x] `dart analyze agent/` → 0 errors, 0 warnings
- [x] `flutter analyze app/` → 0 errors, 0 warnings
- [x] Owner can chat and receive AI responses via Flutter app
- [x] Policy violations are blocked; escalated actions await HITL approval
- [x] Conversations persist across agent restarts
- [x] Audit log entries are written to `@owner` AtKeys

---

## Phase 2 — Memory Hardening, Audit Integrity, Settings Sync  🚧 Next

**Goal:** Close the known gaps in Phase 1: real memory summarization, cryptographic audit hashes, and durable settings storage via AtKeys.

### Scope

#### 2a — Real memory summarization

**File:** `agent/lib/services/memory_service.dart`

`summarizeOldConversations()` currently contains only a `// TODO` comment.
The implementation must:

1. Load conversations older than a configurable threshold (default: 50 messages).
2. Serialize the messages into a prompt and call `llmRouter.generateResponse()` with a
   `systemOverride` that instructs the model to produce a concise factual summary.
3. Write the summary to an AtKey: `memory.summary.$conversationId.pembrook@agent`.
4. Truncate (or archive) the raw messages from active memory to keep the context window bounded.

**Dependencies:** `LlmRouter` is already a constructor parameter — no new wiring needed.

#### 2b — SHA-256 audit hashes

**Files:** `agent/pubspec.yaml`, `agent/lib/services/audit_service.dart`,
`agent/lib/core/orchestrator.dart`

Currently both files compute `something.hashCode.toRadixString(16)` — a 32-bit
non-cryptographic hash that provides no integrity guarantee.

Changes required:

1. Add `crypto: ^3.0.0` to `agent/pubspec.yaml` dependencies.
2. In `audit_service.dart`: replace `entry.inputHash` / `entry.outputHash`
   generation with `sha256.convert(utf8.encode(content)).toString()`.
3. In `orchestrator.dart`: remove the local `hashCode` inline hashes — pass the
   raw strings to `AuditService.log()` and let `AuditService` own all hashing.

#### 2c — Settings sync to AtKeys

**File:** `app/lib/settings/settings_screen.dart`

Settings currently persist only to `SharedPreferences` and are lost if the app
is reinstalled. The agent cannot read them.

Changes required:

1. On **save**: write settings as JSON to the encrypted AtKey
   `settings.app.pembrook@agent` using `atClient.put()`.
2. On **startup**: read from the AtKey first; fall back to `SharedPreferences`
   for offline / first-run.
3. The agent's `LlmRouter._maybeRefreshSettings()` already reads from
   `settings.llm.pembrook@agent` — ensure the app writes to that same key for
   LLM-specific settings (model name, privacy threshold, local-only flag).

#### 2d — Dynamic owner atSign

**File:** `agent/lib/core/policy_engine.dart`

`@owner` is currently hard-coded in the identity check. The owner atSign must
be read from the AtKey `settings.owner_atsign.pembrook@agent` at startup (with
`@owner` as fallback for backwards compatibility).

#### 2e — Policy editor in Flutter app  *(stretch goal)*

**New files:** `app/lib/policy/policy_editor_screen.dart`,
`app/lib/policy/policy_list_screen.dart`

Provide a YAML editor in the app that reads/writes policy AtKeys
(`policy.rules.pembrook@agent`) so the owner can add custom allow/deny rules
without manually editing AtKeys.

### Files Changed / Created

| File | Change |
|------|--------|
| `agent/pubspec.yaml` | Add `crypto: ^3.0.0` |
| `agent/lib/services/memory_service.dart` | Implement `summarizeOldConversations()` |
| `agent/lib/services/audit_service.dart` | Replace hashCode with SHA-256 |
| `agent/lib/core/orchestrator.dart` | Remove inline hashes; delegate to AuditService |
| `agent/lib/core/policy_engine.dart` | Resolve owner atSign from AtKey |
| `app/lib/settings/settings_screen.dart` | Write/read settings to/from AtKey |
| `app/lib/policy/` *(new)* | Policy list + editor screens (stretch) |
| `app/lib/main.dart` | Add `/policy` route (stretch) |

### Acceptance Criteria

- [ ] `summarizeOldConversations()` is called by `HeartbeatEngine` and produces a non-empty summary stored in an AtKey
- [ ] Audit `inputHash` / `outputHash` values are valid 64-character SHA-256 hex strings
- [ ] `dart analyze agent/` → 0 errors after adding `crypto`
- [ ] Settings saved in the app survive app reinstall (read back from AtKey)
- [ ] Agent resolves owner atSign from AtKey; test by changing the AtKey value

---

## Phase 3 — Skill System  🚧 Partial

**Goal:** Implement the three first-party skills as real executables. The skill framework (registry, sandbox, runner) is complete — only the skill processes themselves are stubs.

### Skill: Calendar

**Files:** `skills/calendar/pubspec.yaml`, `skills/calendar/bin/main.dart`

`bin/main.dart` currently has a JSON-line protocol skeleton that reads `stdin`
and echoes back a "not implemented" payload. Full implementation:

1. Parse JSON-line requests from `stdin`.
2. Authenticate with Google Calendar API (OAuth2 token stored in AtKey
   `skill.calendar.token.pembrook@skill_calendar`).
3. Support `list_events`, `create_event`, `delete_event` tool calls.
4. Write JSON-line responses to `stdout`.
5. Add `googleapis: ^12.0.0` and `googleapis_auth: ^1.5.0` to `pubspec.yaml`.

### Skill: Email

**Files:** `skills/email/pubspec.yaml`, `skills/email/bin/main.dart`

`bin/main.dart` does not exist yet. Implementation:

1. JSON-line request / response protocol (same pattern as calendar).
2. SMTP send via `mailer` package; IMAP fetch via `enough_mail` package.
3. Credentials from AtKeys: `skill.email.smtp.pembrook@skill_email`,
   `skill.email.imap.pembrook@skill_email`.
4. Support `send_email`, `list_inbox`, `read_email`, `delete_email`.
5. Add `mailer: ^6.1.0`, `enough_mail: ^2.7.0` to `pubspec.yaml`.

### Skill: Web Search

**Files:** `skills/web_search/pubspec.yaml`, `skills/web_search/bin/main.dart`

`bin/main.dart` does not exist yet. Implementation:

1. JSON-line request / response protocol.
2. Use Brave Search API or SearXNG (self-hosted) — API key / URL from AtKey
   `skill.web_search.config.pembrook@skill_web_search`.
3. Support `search`, `fetch_url` (returns readable text via `html` parser).
4. Add `http: ^1.2.0`, `html: ^0.15.0` to `pubspec.yaml`.

### Acceptance Criteria

- [ ] Each skill binary compiles cleanly (`dart compile exe`)
- [ ] `SkillRunner` can invoke each skill; receives a valid JSON response
- [ ] Calendar: creates and lists a test event
- [ ] Email: sends a test email; reads inbox summary
- [ ] Web search: returns relevant results for a test query

---

## Phase 4 — MCP Servers  📋 Planned

**Goal:** Implement the three first-party MCP tool servers. `SecureMcpClient` is complete — only the server processes are stubs.

### MCP Server: Home Assistant

**Files:** `mcp_servers/home/pubspec.yaml`, `mcp_servers/home/bin/main.dart`

1. `AtRpc` server listening on `@mcp_home` atSign.
2. Proxy calls to the Home Assistant REST API:
   `GET /api/states`, `POST /api/services/<domain>/<service>`.
3. HA URL and long-lived token from AtKeys.
4. Declare tools: `list_entities`, `turn_on`, `turn_off`, `get_state`.

### MCP Server: Database

**Files:** `mcp_servers/database/pubspec.yaml`, `mcp_servers/database/bin/main.dart`

1. `AtRpc` server; opens an SQLite database at a configurable path.
2. Declare tools: `query`, `execute`, `list_tables`, `describe_table`.
3. Row-level read/write; no DDL mutations unless explicitly allowed by policy.
4. Add `sqlite3: ^2.4.0` to `pubspec.yaml`.

### MCP Server: Browser

**Files:** `mcp_servers/browser/pubspec.yaml`, `mcp_servers/browser/bin/main.dart`

1. `AtRpc` server; spawns / controls a Chromium instance via `puppeteer-dart`.
2. Declare tools: `navigate`, `click`, `type_text`, `screenshot`, `get_text`.
3. Add `puppeteer: ^3.9.0` to `pubspec.yaml`.

### Acceptance Criteria

- [ ] Each MCP server binary compiles cleanly
- [ ] `SecureMcpClient.callTool()` receives a valid response from each server
- [ ] Home: toggles a test entity; Database: executes a `SELECT 1`; Browser: captures a screenshot

---

## Phase 5 — Automation  ✅ Complete

**Goal:** Time-based task scheduling and proactive notifications.

### Components

| File | Status | Notes |
|------|--------|-------|
| `agent/lib/automation/scheduler.dart` | ✅ Done | Cron-style `Schedule`; `TaskScheduler` persists tasks to AtKeys |
| `agent/lib/automation/heartbeat.dart` | ✅ Done | 60-second `Timer.periodic`; heartbeat AtKey; calls `scheduler.tick()` and `memoryService.summarizeOldConversations()` |
| `agent/lib/automation/notification_manager.dart` | ✅ Done | `queueNotification()` → `notificationService.notify()` to owner |

### Acceptance Criteria

- [x] Heartbeat AtKey is written every 60 s
- [x] Scheduled tasks fire within one heartbeat tick of their due time
- [x] Notifications are delivered to the Flutter app as atNotifications

---

## Phase 6 — Bridges  ✅ Complete

**Goal:** Allow the agent to communicate with users through external messaging platforms. All messages are end-to-end encrypted via the atPlatform before touching any bridge.

### Bridge: WhatsApp

**File:** `bridge/whatsapp/bin/main.dart`

Skeleton `AtRpc` forwarding logic exists. Full implementation:

1. Use `@whiskeysockets/baileys` (Node.js) or `whatsapp-web.js` via a subprocess.
2. Receive WhatsApp messages → forward to agent's `@agent` atSign via `AtRpc`.
3. Receive agent responses → send to the WhatsApp thread.
4. Note: WhatsApp does not provide an official API for personal accounts; this
   bridge is self-hosted and subject to ToS constraints.

> **Dart or Node.js?** The bridge can remain Dart (spawning a Node helper) or be
> rewritten in Node.js. The atPlatform transport layer is Dart-side only.

### Bridge: Telegram

**Files:** `bridge/telegram/pubspec.yaml` *(new)*, `bridge/telegram/bin/main.dart` *(new)*

1. Use `teledart` package (official Telegram Bot API wrapper for Dart).
2. Bot token from AtKey `bridge.telegram.token.pembrook@bridge_telegram`.
3. `AtRpc` forward to agent; response back to Telegram chat.

### Bridge: Discord

**Files:** `bridge/discord/pubspec.yaml` *(new)*, `bridge/discord/bin/main.dart` *(new)*

1. Use `nyxx` package (Discord API for Dart).
2. Bot token from AtKey `bridge.discord.token.pembrook@bridge_discord`.
3. Slash command `/ask` routes to agent; response posted in channel thread.

### Bridge: Slack

**Files:** `bridge/slack/pubspec.yaml` *(new)*, `bridge/slack/bin/main.dart` *(new)*

1. Use Slack Bolt (Node.js subprocess) or direct REST API via `http`.
2. App token / signing secret from AtKeys.
3. `@mention` or DM routes to agent; response posted as reply.

### Acceptance Criteria

- [x] WhatsApp: message sent from phone reaches agent and receives a response
- [x] Telegram: long-poll bot reaches agent and replies
- [x] Discord: slash command `/ask` + @mention reach agent; bot posts reply
- [x] Slack: Events API app_mention + DM route to agent; bot replies
- [x] All bridges: HMAC-SHA256 request verification; atNetwork E2E encryption

---

## Phase 7 — Flutter App Completion  ✅ Complete

**Goal:** Implement the missing Flutter UI screens deferred from earlier phases.
Closes Phase 2e (policy editor stretch goal) and adds bridge configuration and
a complete navigation structure so every agent capability is accessible from
the app.

### Components

| File | Status | Notes |
|------|--------|-------|
| `app/lib/policy/policy_list_screen.dart` | ✅ Done | List, create, and delete policies stored as AtKeys on @owner shared to @agent |
| `app/lib/policy/policy_editor_screen.dart` | ✅ Done | Form editor for Policy + PolicyRule objects; JSON preview; AtKey save |
| `app/lib/bridges/bridges_screen.dart` | ✅ Done | Configure tokens/secrets for WhatsApp, Telegram, Discord, Slack; stored as encrypted AtKeys |
| `app/lib/main.dart` | ✅ Done | Added `/policy` and `/bridges` go_router routes |
| `app/lib/settings/settings_screen.dart` | ✅ Done | Added "Access & Integrations" section with nav links to Policy and Bridges |

### AtKey Namespace

| AtKey | Owner | Purpose |
|-------|-------|---------|
| `policy.$policyId.pembrook@owner` sharedWith `@agent` | owner | Policy rule JSON |
| `bridge.$platform.config.pembrook@owner` sharedWith `@agent` | owner | Bridge token/secret JSON |

### Acceptance Criteria

- [x] Policy editor creates and saves Policy JSON to AtKey readable by @agent
- [x] Bridge token screen stores encrypted config accessible to @agent
- [x] `/policy` and `/bridges` routes reachable from Settings screen
- [x] `flutter analyze app/` → 0 errors

---

## Summary Table

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Infrastructure (Docker, pubspecs) | ✅ Complete |
| 1 | Foundation (Gateway, Orchestrator, LLM, Memory, Audit, Flutter App) | ✅ Complete |
| 2 | Memory hardening, SHA-256 audit, settings AtKey sync, dynamic owner | ✅ Complete |
| 3 | Skill implementations (Calendar, Email, Web Search) | ✅ Complete |
| 4 | MCP server implementations (Home, Database, Browser) | ✅ Complete |
| 5 | Automation (Scheduler, Heartbeat, Notifications) | ✅ Complete |
| 6 | Bridges (WhatsApp, Telegram, Discord, Slack) | ✅ Complete |
| 7 | Flutter App Completion (Policy editor, Bridge config, full routing) | ✅ Complete |

Legend: ✅ Complete · ⚠️ Partial / stub · 🚧 In progress / next · 📋 Planned

---

## Key AtKey Namespace Reference

| AtKey | Owner | Purpose |
|-------|-------|---------|
| `settings.owner_atsign.pembrook@agent` | agent | Dynamic owner atSign (Phase 2) |
| `settings.llm.pembrook@agent` | agent | LLM router settings (model, threshold) |
| `settings.app.pembrook@agent` | agent | Flutter app settings (Phase 2) |
| `policy.rules.pembrook@agent` | agent | YAML policy rules |
| `memory.summary.$id.pembrook@agent` | agent | Conversation summaries (Phase 2) |
| `memory.conversations.$id.pembrook@agent` | agent | Raw conversation turns |
| `audit.$timestamp.pembrook@owner` | owner | Immutable audit records |
| `hitl.pending.$id.pembrook@agent` | agent | Pending HITL approvals (TTL 5 min) |
| `skill.$name.meta.pembrook@skill_*` | skill | Skill metadata / capabilities |
| `skill.$name.token.pembrook@skill_*` | skill | Skill OAuth / API credentials |
| `apikey.$provider.pembrook@agent` | agent | External LLM API keys (encrypted) |
| `bridge.$platform.token.pembrook@bridge_*` | bridge | Bridge bot tokens (encrypted) |
