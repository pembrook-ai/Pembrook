# Pembrook Browser MCP Server
# Multi-stage build: compile to native binary, then copy into minimal runtime.
#
# Build (run from repo root):
#   docker build -t pembrook-mcp-browser:latest mcp_servers/browser/
#
# NOTE: browser.fetch and browser.extract_text work without any sidecar.
# browser.screenshot / click / fill_form require a Playwright sidecar —
# pass playwrightWsUrl in the tool arguments.

# ── Stage 1: compile ──────────────────────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /app

COPY mcp_servers/browser/pubspec.yaml mcp_servers/browser/pubspec.lock* ./
RUN dart pub get

COPY mcp_servers/browser/ .
RUN dart compile exe bin/main.dart -o /mcp_server

# ── Stage 2: minimal runtime ──────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /mcp_server /mcp_server

ENTRYPOINT ["/mcp_server"]
