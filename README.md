# Pembrook — Secure AI Agent Platform

A privacy-first, zero-trust AI agent built on the [atPlatform](https://docs.atsign.com/core). Pembrook eliminates the entire class of network-exposure and supply-chain vulnerabilities that plagued OpenClaw, replacing them with cryptographic identity, E2E encryption, and skill sandboxing — all with **zero open inbound ports** on any component.

See [ATPLATFORM_GUIDELINES.md](ATPLATFORM_GUIDELINES.md) for the complete atPlatform SDK reference.  
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for internal design, data-flow, component contracts, and implementation decisions.  
See [GETTING_STARTED.md](GETTING_STARTED.md) for full setup instructions including chat history, skills, MCP servers, and bridges.

---

## Security at a Glance

| Threat | OpenClaw | Pembrook |
|---|---|---|
| Network exposure | Port 18789 open to internet (30,000+ exposed) | **Zero open ports** — all outbound-only |
| Authentication | None by default | Cryptographic atSign PKAM verification |
| Credentials | Plaintext `.env` files | Encrypted AtKeys, never plaintext |
| Skills/plugins | ClawHub (386 malicious packages in days) | Verified developer atSign + Docker sandbox |
| Prompt injection | Full agent authority | Untrusted input tagged, restricted context |
| Memory poisoning | All inputs equal authority | Source-tagged trust levels, non-escalatable |
| Confused deputy | Agent tricked into misusing tools | Context-aware tool filter per task type |
| Supply chain | Anonymous publishing | Developer identity required, signed packages |
| Lateral movement | Full home directory access | Pico-segmented per-skill / per-tool |
| Audit | None | Immutable AtKeys on owner's atServer |

---

## Architecture Overview

```
Owner (@owner)
  │  ┌─── Flutter App (macOS/iOS/Windows/Linux/Android/Web)
  │  │         │  AtRpcClient
  │  │         ▼
  │  └──── atPlatform Network (E2E encrypted, zero ports)
  │                │  AtRpc
  ▼                ▼
Messaging       Agent Gateway (@agent)
Bridges           │  allowList: {@owner, @bridge_*}
(@bridge_*)       │
                  ├── Policy Engine (check every action)
                  │
                  ├── Agent Orchestrator
                  │     ├── LLM Router
                  │     │     ├── Local LLM (Ollama, localhost:11434)
                  │     │     └── Query Sanitizer → External LLM (optional)
                  │     ├── Memory Service (AtKeys on @agent)
                  │     ├── Audit Service (immutable AtKeys on @owner)
                  │     ├── Skill Executor → Sandbox Manager → Skills (@skill_*)
                  │     └── MCP Client → atPlatform → MCP Servers (@mcp_*)
                  │
                  └── Automation
                        ├── Task Scheduler
                        ├── Heartbeat Engine
                        └── Notification Manager
```

All connections are **outbound-only** to the atPlatform. No component has any open inbound port.

---

## Repository Layout

```
pembrook/
├── ATPLATFORM_GUIDELINES.md   # atPlatform SDK reference (do not add project specifics here)
├── README.md                  # This file — project documentation
├── agent/                     # Dart CLI — the AI agent daemon
│   ├── pubspec.yaml
│   ├── bin/main.dart          # Entry point: CLIBase auth → start Gateway
│   └── lib/
│       ├── core/              # Orchestrator, PolicyEngine, HitlManager
│       ├── services/          # LlmRouter, Sanitizer, MemoryService, AuditService
│       ├── gateway/           # AtRpc server (Gateway + Callbacks)
│       ├── skills/            # SkillRegistry, SandboxManager, SkillRunner
│       ├── mcp/               # SecureMcpClient
│       ├── automation/        # Scheduler, Heartbeat, NotificationManager
│       └── models/            # Policy, Conversation, AuditEntry, SkillMetadata, Task
├── app/                       # Flutter cross-platform UI
│   ├── pubspec.yaml
│   └── lib/
│       ├── auth/              # AuthScreen + all 4 auth workflows
│       ├── chat/              # ChatScreen + real-time streaming
│       ├── settings/          # LLM settings, atSign management
│       ├── policy/            # YAML policy editor
│       ├── skills/            # Skill browser
│       ├── audit/             # Audit log viewer
│       ├── hitl/              # HITL approval dialogs
│       └── services/          # RpcService, DataService
├── bridge/                    # Messaging bridge agents (Phase 6)
├── mcp_servers/               # MCP server wrappers (Phase 4)
│   ├── home/                  # Home Automation (@mcp_home)
│   ├── database/              # Database (@mcp_db)
│   └── browser/               # Web Browser (@mcp_browser)
├── skills/                    # Built-in skill packages (Phase 3)
│   ├── calendar/              # Calendar skill (@skill_cal)
│   ├── email/                 # Email skill (@skill_email)
│   └── web_search/            # Web search skill (@skill_search)
├── docker-compose.yml         # Starts agent + Ollama + MCP servers
└── Dockerfile.agent           # Compiles and packages the agent
```

---

## atSign Provisioning Map

Register all atSigns at [my.atsign.com](https://my.atsign.com) before first run.

| atSign | Purpose | Phase |
|---|---|---|
| `@owner` | Human owner — primary identity | 1 |
| `@agent` | AI agent core — all agent operations | 1 |
| `@bridge_whatsapp` | WhatsApp relay | 6 |
| `@bridge_telegram` | Telegram relay | 6 |
| `@bridge_discord` | Discord relay | 6 |
| `@bridge_slack` | Slack relay | 6 |
| `@skill_cal` | Calendar skill | 3 |
| `@skill_email` | Email skill | 3 |
| `@skill_search` | Web search skill | 3 |
| `@mcp_home` | Home automation MCP server | 4 |
| `@mcp_db` | Database MCP server | 4 |
| `@mcp_browser` | Browser automation MCP server | 4 |

> Replace all placeholder atSigns above with your actual provisioned atSigns before deployment.

---

## Namespace

All application data uses namespace **`pembrook`**.

Key format: `keyname.pembrook@atsign`

---

## AtKey Naming Conventions

| Key Pattern | Owner atServer | Purpose | TTL |
|---|---|---|---|
| `conversation.$convId.pembrook@owner` | `@owner` | Chat history (app) | 90 days |
| `conversation.$convId.pembrook@agent` | `@agent` | Agent-side conversation | 90 days |
| `context.user_preferences.pembrook@agent` | `@agent` | Owner preferences | — |
| `context.user_profile.pembrook@agent` | `@agent` | Personal info | — |
| `settings.llm.pembrook@agent` | `@agent` | LLM config (model, threshold) | — |
| `settings.app.pembrook@owner` | `@owner` | App UI preferences | — |
| `settings.heartbeat.pembrook@agent` | `@agent` | Heartbeat cadence | — |
| `policy.$policyId.pembrook@agent` | `@agent` | Policy rules (YAML) | — |
| `skill_meta.$skillId.pembrook@agent` | `@agent` | Installed skill registry | — |
| `skill_state.$skillId.pembrook@agent` | `@agent` | Per-skill persistent state | — |
| `schedule.$taskId.pembrook@agent` | `@agent` | Scheduled task definition | — |
| `task.$taskId.pembrook@agent` | `@agent` | Active task state | — |
| `audit.$ts.$actionId.pembrook@owner` | `@owner` | **Immutable** audit log | — |
| `hitl.pending.$actionId.pembrook@agent` | `@agent` | Pending HITL approval | 5 min |
| `apikey.$provider.pembrook@agent` | `@agent` | Encrypted external API keys | — |
| `email.draft.$draftId.pembrook@agent` | `@agent` | Email drafts awaiting HITL | 7 days |
| `calendar.$eventId.pembrook@owner` | `@owner` | Calendar entries | — |
| `summary.$period.pembrook@agent` | `@agent` | Compressed conversation summaries | — |
| `digest.$date.pembrook@owner` | `@owner` | Daily notification digest | 30 days |

> Audit keys use `Metadata()..immutable = true` — once written, they cannot be modified.
> Audit keys are stored on `@owner`'s atServer so the agent cannot delete its own logs.

---

## AtRpc Message Formats

### Flutter App → Agent (chat command)

```json
{
  "command": "What's on my calendar tomorrow?",
  "conversationId": "conv-uuid-1234",
  "timestamp": 1741824000000
}
```

### Agent → Flutter App (streaming response chunk)

```json
{
  "conversationId": "conv-uuid-1234",
  "chunk": "You have a team standup at 9am...",
  "done": false,
  "chunkIndex": 3
}
```

### Messaging Bridge → Agent (inbound message)

```json
{
  "text": "Remind me about the meeting at 3pm",
  "senderAtSign": "@owner",
  "platform": "whatsapp",
  "timestamp": 1741824000000,
  "messageType": "text"
}
```

### Policy Engine → HITL Manager (approval request)

```json
{
  "actionId": "action-uuid-5678",
  "action": "send_email",
  "context": "Sending email to bob@example.com with subject 'Q1 Report'",
  "riskAssessment": "Outbound communication — HITL required by policy",
  "options": ["approve", "deny"],
  "timeoutSeconds": 300
}
```

### Audit Entry (stored as immutable AtKey on @owner)

```json
{
  "timestamp": 1741824000000,
  "actionType": "skill_invocation",
  "initiatorAtSign": "@owner",
  "targetResource": "email.draft.abc123",
  "policyDecision": "escalate_hitl",
  "inputHash": "sha256:abc...",
  "outputHash": "sha256:def...",
  "executionDurationMs": 1200,
  "skillId": "email_skill",
  "mcpServer": null
}
```

---

## Data Flow: Interactive Chat

```
Owner types → Flutter app
  → AtRpcClient.call({command, conversationId}) → atPlatform
    → Gateway.handleRequest() — verifies sender in allowList
      → PolicyEngine.checkPolicy() — identity + capability + temporal check
        → Orchestrator.processRequest()
          → MemoryService.loadConversation() — AtKey get()
          → LlmRouter.classifyIntent() — Ollama POST
          → LlmRouter.scorePrivacy() — Ollama POST
          → LlmRouter.generateResponse() — Ollama POST (streaming)
            → Gateway streams response chunks → atPlatform
              → Flutter app notification subscription
                → Chat UI displays tokens
          → MemoryService.saveExchange() — AtKey put()
          → AuditService.log() — immutable AtKey on @owner
```

## Data Flow: Skill Invocation

```
Orchestrator identifies skill need
  → SkillRegistry.getSkill() — AtKey read
  → PolicyEngine.checkPolicy(skill capabilities)
    → If HITL required:
        → HitlManager.requestApproval() — notify @owner
          → Owner approves in Flutter app → AtRpc response
    → SandboxManager.executeInSandbox()
        → Docker: --rm --network=none --memory=256m --cpus=0.5
          → Skill AtRpc server receives task from Orchestrator
          → Skill reads/writes only its declared namespace
          → Returns result via AtRpc
      → SandboxManager destroys container
      → AuditService.log(sandbox events)
```

---

## Deployment

### Local (Docker Compose)

```bash
# 1. Provision atSigns at my.atsign.com and save .atKeys files to ~/.atsign/keys/
# 2. Configure the agent (run once, or when settings change):
dart run agent/bin/init_config.dart \
  --atsign @youragent \
  --key-file ~/.atsign/keys/@youragent_key.atKeys \
  --owner @you \
  --ollama-model qwen2.5:7b \
  --allowed-users @you

# 3. Pull the Ollama model:
docker compose run --rm ollama ollama pull qwen2.5:7b

# 4. Start (CPU — works on macOS, Windows, Linux):
docker compose up -d

# 4a. Start (GPU — Linux + NVIDIA only, requires nvidia-container-toolkit):
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d

# Tail agent logs:
docker compose logs -f agent
```

> **GPU setup (Linux + NVIDIA):** Install [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html), then run:
> ```bash
> sudo nvidia-ctk runtime configure --runtime=docker
> sudo systemctl restart docker
> ```
> Then use the `docker-compose.gpu.yml` override above. macOS and Windows use CPU mode automatically.

### Cloud VPS (zero open ports)

```bash
# Same as local — no security group inbound rules needed.
# SSH access: use NoPorts instead of opening port 22.

# CPU:
docker compose up -d

# GPU (if VPS has NVIDIA — see GPU setup note above):
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

### Verify zero open ports

```bash
nmap -p- localhost  # should show 0 open ports (Ollama binds loopback only)
```

---

## Implementation Phases

| Phase | Components | Status |
|---|---|---|
| **Phase 1** | Gateway + Orchestrator + Ollama + Flutter App | 🚧 In Progress |
| **Phase 2** | Memory Service + Audit + Policy Engine | 📋 Planned |
| **Phase 3** | Skill System + Sandbox + Calendar/Email/Search skills | 📋 Planned |
| **Phase 4** | MCP Integration + Home/DB/Browser MCP servers | 📋 Planned |
| **Phase 5** | Heartbeat + Scheduler + Notifications | 📋 Planned |
| **Phase 6** | Messaging Bridges (WhatsApp, Telegram, Discord, Slack) | 📋 Planned |

---

## Prerequisites

- [Dart SDK](https://dart.dev/get-dart) `>=3.6.0`
- [Flutter SDK](https://flutter.dev/docs/get-started/install)
- [Docker](https://docs.docker.com/get-docker/) (for Ollama and skill sandbox)
- [Ollama](https://ollama.ai) running locally: `docker run -d -p 127.0.0.1:11434:11434 ollama/ollama`
- atSigns provisioned at [my.atsign.com](https://my.atsign.com)

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD 3-Clause — see [LICENSE](LICENSE).

## Maintainers

- [cconstab](https://github.com/cconstab)
