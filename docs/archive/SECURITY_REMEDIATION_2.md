# Security Remediation — Round 2

Findings from second audit (April 2026).  
Previous remediation archived at `docs/archive/SECURITY_REMEDIATION_2026-04-14.md`.

---

## P0 — Fix Now

### H1: SSRF Bypass via HTTP Redirects
- **Files:** `agent/lib/core/orchestrator.dart`, `mcp_servers/browser/bin/main.dart`
- **Issue:** `UrlValidator.validate()` runs before `http.get()`, but the Dart http client follows redirects automatically. A redirect to `http://169.254.169.254/` or `http://localhost:11434/` is never re-validated.
- **Status:** [x] Complete

### H2: DNS Rebinding / TOCTTOU in SSRF Validation
- **Files:** `agent/lib/core/url_validator.dart`, `mcp_servers/browser/bin/main.dart`
- **Issue:** DNS is resolved in `validate()` but the `http` package re-resolves independently. Attacker DNS returns safe IP for validation, private IP for the actual connection.
- **Status:** [x] Complete

### H3: Log Viewer Has Raw Docker Socket Access
- **Files:** `docker-compose.yml`, `tools/log_viewer/server.py`, `tools/log_viewer/Dockerfile`
- **Issue:** `log_viewer` mounts `/var/run/docker.sock` directly (`:ro` does not prevent writes at the protocol level). Exploitation of the log viewer gives full Docker API access → host escape.
- **Status:** [x] Complete

### L4: WhatsApp Webhook Verify Token Reuses Access Token
- **File:** `bridge/whatsapp/bin/main.dart`
- **Issue:** `hub.verify_token` is compared against `config.token` (the Cloud API access token). If Meta logs the verify_token parameter, the high-privilege access token is exposed.
- **Status:** [x] Complete

---

## P1 — This Sprint

### M1: Log Viewer Auth Token Is Optional
- **File:** `tools/log_viewer/server.py`
- **Issue:** `LOG_VIEWER_TOKEN` is opt-in; service starts without it. Unauthenticated SSE stream leaks all container logs.
- **Status:** [x] Complete

### M2: Prompt Injection via Fetched Web Content
- **Files:** `agent/lib/core/orchestrator.dart`, `agent/lib/services/llm_router.dart`
- **Issue:** Raw fetched web content is injected directly into LLM context. Malicious pages can embed instructions to exfiltrate data via `send_email` or `schedule_task`.
- **Fix:** Wrap fetched content in clear boundary markers; add system-prompt instruction that content between markers is untrusted data, never instructions. Gate high-risk tool calls (send_email, schedule_task) on HITL when conversation includes externally-fetched content.
- **Status:** [x] Complete
  - `_fetchWebpage()` and MCP `browser.*` results wrapped in `--- UNTRUSTED WEB CONTENT BEGIN/END ---` markers; `_requestHasExternalContent` flag tracks exposure per request
  - `llm_router.dart` `toolSystemPrompt` includes explicit instruction to treat content between markers as untrusted data, never as instructions
  - `_executeTool()` gates `send_email` and `schedule_task` on `hitlManager.requestApproval()` when `_requestHasExternalContent` is true

### M4: Skill `--network=bridge` Too Broad
- **File:** `agent/lib/skills/sandbox_manager.dart`
- **Issue:** Network-requiring skills run with `--network=bridge`, giving access to the full pembrook_internal network and internet. Built-in skill IDs auto-grant `['*']` wildcard endpoints.
- **Fix:** Create a dedicated isolated `skill_net` per invocation; use `--network=skill_net` instead of `bridge`. Remove the wildcard auto-grant from `gateway_callbacks.dart`.
- **Status:** [x] Complete
  - `docker-compose.yml`: new `pembrook_skill_net` (bridge, internal:false) — provides internet but has no attachment to `pembrook_internal` so skills cannot reach agent/atsdk
  - `sandbox_manager.dart`: `--network=bridge` → `--network=pembrook_skill_net`
  - `gateway_callbacks.dart`: wildcard `['*']` replaced with protocol-specific labels (`['smtp','imap']`, `['caldav','https']`, `['https']`) for audit trail clarity

---

## P2 — Next Sprint

### M3: Shared `SERVICES_AT_SIGN` Lateral Movement
- **Files:** `agent/bin/main.dart`
- **Issue:** Default config shares one atSign across all bridges and MCP servers. Compromising one service compromises all.
- **Fix (accepted default):** Per-service atSigns are not required as the default — the shared atSign is intentional for self-hosted single-user deployments. A startup WARNING is emitted whenever `SERVICES_AT_SIGN` is set so the trade-off is always visible in logs.
- **Status:** [x] Complete
  - `main.dart`: `log.warning('M3-NOTICE: …')` printed at every startup when `SERVICES_AT_SIGN` is non-empty

### M5: Ollama Has No Authentication
- **Files:** `docker-compose.yml`
- **Issue:** Ollama listens on `ollama_net` with no auth. A compromised service on a shared network could potentially reach it.
- **Fix:** Set `OLLAMA_ORIGINS` to restrict allowed origins. Verify `ollama_net` is only attached to `agent` and `ollama` containers (currently correct — document this constraint explicitly).
- **Status:** [x] Complete
  - `docker-compose.yml`: `OLLAMA_ORIGINS: "http://pembrook-agent"` added to ollama service
  - `ollama_net` is `internal: true` and attached only to `agent` + `ollama` — constraint now documented in the network comment

### I2: Error Messages Leak Internal State
- **Files:** `agent/lib/gateway/gateway_callbacks.dart`, `agent/lib/core/orchestrator.dart`, `agent/lib/skills/sandbox_manager.dart`
- **Issue:** Raw exception strings (`$e`) returned to callers expose stack traces, file paths, and internal service names.
- **Fix:** Return generic messages to callers; log full detail internally only.
- **Status:** [x] Complete
  - `gateway_callbacks.dart`: `'Internal error: $e'` → `'An internal error occurred.'`; `'Sys command failed: $e'` → `'System command failed.'`
  - `sandbox_manager.dart`: `'Sandbox error: $e'` → `'Sandbox execution failed.'`
  - `orchestrator.dart`: `'Error fetching $uri: $e'` → `'Error: failed to retrieve content from $uri'` (URL retained, exception detail removed)

### I3: Log Viewer Dockerfile Uses `get.docker.com` Script
- **File:** `tools/log_viewer/Dockerfile`
- **Issue:** `curl https://get.docker.com | sh` bypasses version pinning and GPG verification.
- **Fix:** Install Docker CLI from the official apt repository with a pinned version, matching the agent Dockerfile pattern.
- **Status:** [x] Complete
  - `tools/log_viewer/Dockerfile`: replaced `curl | sh` with official Docker apt repo + GPG keyring validation, identical pattern to `Dockerfile.agent`

---

## P3 — Backlog / Accept

### L1: TLS — SPKI Pinning Not Yet Implemented
- **File:** `agent/lib/services/llm_router.dart`
- **Issue:** Badcert callback is informational; no SPKI fingerprint check. A rogue CA could MitM API keys.
- **Fix:** Implement SPKI SHA-256 pinning. Requires cert rotation process to be in place first.
- **Status:** [ ] (accept until cert rotation process defined)

### L2: PII Sanitizer LLM Accuracy
- **File:** `agent/lib/services/sanitizer.dart`
- **Issue:** Small local model misses context-dependent PII. Regex pre-filter covers common patterns only.
- **Fix:** Add regex patterns for DOB, driver's licence, passport. Log all external LLM queries for retroactive PII audit.
- **Status:** [ ]

### L3: Rate Limit Persistence Race Condition
- **File:** `agent/lib/gateway/gateway_callbacks.dart`
- **Issue:** Fire-and-forget `_persistRateLimits()` loses counters on crash. Known trade-off, acknowledged in code.
- **Fix (optional):** Add secondary in-process token-bucket limiter as a backstop.
- **Status:** [ ] (accept)

### I1: fetch_webpage Chrome User-Agent
- **File:** `agent/lib/core/orchestrator.dart`
- **Issue:** Sends Chrome UA string — pragmatically useful but deceptive.
- **Fix:** Add code comment explaining the intent; consider `PembrookBot/1.0` for honest crawling.
- **Status:** [ ] (accept)

---

## Summary

| Phase | IDs | Items |
|-------|-----|-------|
| **P0 — Now** | H1, H2, H3, L4 | Redirect SSRF, DNS rebind, log viewer socket, webhook token |
| **P1 — This sprint** | M1, M2, M4 | Log viewer auth, prompt injection, skill network |
| **P2 — Complete** | M3, M5, I2, I3 | Shared atSign warning, Ollama origins, error leakage, Dockerfile |
| **P3 — Backlog** | L1, L2, L3, I1 | SPKI pinning, PII regex, rate limit race, UA string |
