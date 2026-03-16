# Pembrook Home Automation MCP Server
# Multi-stage build: compile to native binary, then copy into minimal runtime.
#
# Build (run from repo root):
#   docker build -t pembrook-mcp-home:latest mcp_servers/home/
#
# Requires HA_BASE_URL and HA_TOKEN environment variables at runtime.

# ── Stage 1: compile ──────────────────────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /app

COPY mcp_servers/home/pubspec.yaml mcp_servers/home/pubspec.lock* ./
RUN dart pub get

COPY mcp_servers/home/ .
RUN dart compile exe bin/main.dart -o /mcp_server

# ── Stage 2: minimal runtime ──────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /mcp_server /mcp_server

ENTRYPOINT ["/mcp_server"]
