# Security Audit Remediation Plan

**Report Date:** 2026-04-07
**Plan Created:** 2026-04-14
**Classification:** CONFIDENTIAL

---

## Phase 0 — P0: Fix Immediately (before next release)

### SEC-006: Weak Audit Hash (Low effort)
- **File:** `agent/lib/gateway/gateway_callbacks.dart`
- **Issue:** `_hash()` uses Dart's non-cryptographic `Object.hashCode` (32-bit) for audit log entries.
- **Fix:** Replace `_hash()` with `AuditService.contentHash()` which already provides SHA-256 via the `crypto` package.
- **Status:** [x] Complete

### SEC-002: Log Viewer Exposed on 0.0.0.0 (Low effort)
- **Files:** `tools/log_viewer/server.py`, `docker-compose.yml`
- **Issue:** Log viewer binds to all interfaces with no authentication — publicly accessible on port 9090.
- **Fix:**
  1. Bind to `127.0.0.1` in `server.py` and `docker-compose.yml`.
  2. Add bearer-token auth (read from `LOG_VIEWER_TOKEN` env var).
  3. Consider moving `log_viewer` to a separate opt-in compose file.
- **Status:** [x] Complete

### SEC-001: SSRF — No Internal IP Filtering (Medium effort)
- **Files:** `agent/lib/core/orchestrator.dart`, `mcp_servers/browser/bin/main.dart`
- **Issue:** `_fetchWebpage`, `_fetchPage`, and `_extractText` accept arbitrary URLs with no filtering of private/reserved IPs.
- **Fix:**
  1. Create `agent/lib/core/url_validator.dart` — resolves hostname, rejects RFC 1918, loopback, link-local, metadata endpoints, and `*.internal` hostnames.
  2. Apply validator in `orchestrator.dart` `_fetchWebpage()` before HTTP request.
  3. Apply validator in `mcp_servers/browser/bin/main.dart` `_fetchPage()` and `_extractText()`.
- **Status:** [x] Complete

---

## Phase 1 — P1: This Sprint

### SEC-005: Webhook Fails Open (Low effort)
- **File:** `bridge/whatsapp/bin/main.dart`
- **Issue:** HMAC-SHA256 verification is skipped when `appSecret` is empty.
- **Fix:** Refuse to start or reject all POSTs if `appSecret` is unconfigured. Verify same pattern in Telegram/Discord/Slack bridges.
- **Status:** [ ]

### SEC-009: Bridge Sender Identity Spoofing (Medium effort)
- **File:** `agent/lib/gateway/gateway_callbacks.dart`
- **Issue:** `effectiveSender` from RPC payload is trusted without cross-validation against `fromAtSign`.
- **Fix:** Validate that service/bridge identities cannot set `effectiveSender` to the owner atSign without explicit authorization. Carry original sender as metadata only.
- **Status:** [ ]

### SEC-008: Sanitizer Fails Open on Error (Medium effort)
- **File:** `agent/lib/services/sanitizer.dart`
- **Issue:** PII sanitizer returns unsanitized query on Ollama failure.
- **Fix:** Return a `failed` flag so the caller falls back to local-only LLM. Add regex-based pre-filter for common PII patterns as defense-in-depth. Log as security audit event.
- **Status:** [ ]

---

## Phase 2 — P2: Next Sprint

### SEC-003: Docker Socket Escape (High effort)
- **Files:** `docker-compose.yml`, `entrypoint-agent.sh`
- **Issue:** Agent container has full read-write Docker socket access — equivalent to host root.
- **Fix:**
  1. Deploy a Docker API proxy (e.g. docker-socket-proxy) restricting to create/start/wait/remove only.
  2. Add AppArmor/SELinux profile for the agent container.
  3. Evaluate rootless Docker or Podman for production docs.
- **Status:** [ ]

### SEC-004: Shared @services Blast Radius (High effort)
- **Files:** `docker-compose.yml`, `.env.example`, docs
- **Issue:** All bridges and MCP servers share a single `@services` atSign.
- **Fix:** Support per-service atSigns (e.g. `WHATSAPP_AT_SIGN`, `MCP_BROWSER_AT_SIGN`). Keep shared atSign as dev-only convenience with bold security warning. Scope PolicyEngine capabilities per-service.
- **Status:** [ ]

### SEC-007: Rate Limiter Resets on Restart (Medium effort)
- **File:** `agent/lib/gateway/gateway_callbacks.dart`
- **Issue:** In-memory `Map<String, List<DateTime>>` resets on container restart.
- **Fix:** Persist rate-limit state to AtKeys with TTL matching the window. Load existing counters on startup. Consider circuit-breaker pattern.
- **Status:** [ ]

---

## Phase 3 — P3: Backlog

### SEC-010: Ollama on Bridge Network (Low effort)
- **File:** `docker-compose.yml`
- **Issue:** Ollama reachable from all containers on the Docker bridge network.
- **Fix:** Create dedicated `ollama_net` Docker network for agent-to-Ollama traffic only. Document `network_mode: host` as recommended Linux production config.
- **Status:** [ ]

### SEC-011: No TLS Certificate Pinning (Medium effort)
- **File:** `agent/lib/services/llm_router.dart`
- **Issue:** Standard HTTPS with no cert pinning for OpenAI/Anthropic API calls.
- **Fix:** Research Dart `SecurityContext` for pinning root CAs. Lower priority — standard HTTPS is acceptable for most threat models.
- **Status:** [ ]

---

## Summary

| Phase | IDs | Items | Est. Effort |
|-------|-----|-------|-------------|
| **P0 — Now** | SEC-006, SEC-002, SEC-001 | Weak hash, log viewer, SSRF | 1–2 days |
| **P1 — This sprint** | SEC-005, SEC-009, SEC-008 | Webhook, spoofing, sanitizer | 2–3 days |
| **P2 — Next sprint** | SEC-003, SEC-004, SEC-007 | Docker socket, shared atSign, rate limiter | 1–2 weeks |
| **P3 — Backlog** | SEC-010, SEC-011 | Ollama network, TLS pinning | Track as tech debt |
