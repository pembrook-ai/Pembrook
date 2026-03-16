# Pembrook Database MCP Server
# Multi-stage build: compile to native binary, then copy into minimal runtime.
#
# Build (run from repo root):
#   docker build -t pembrook-mcp-database:latest mcp_servers/database/
#
# Requires DB_PATH environment variable at runtime (default: /data/pembrook.db).

# ── Stage 1: compile ──────────────────────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /app

COPY mcp_servers/database/pubspec.yaml mcp_servers/database/pubspec.lock* ./
RUN dart pub get

COPY mcp_servers/database/ .
RUN dart compile exe bin/main.dart -o /mcp_server

# ── Stage 2: minimal runtime ──────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /mcp_server /mcp_server

ENTRYPOINT ["/mcp_server"]
