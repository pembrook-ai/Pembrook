# Pembrook Web Search Skill
# Multi-stage build: compile to native binary, then copy into minimal runtime.
#
# Build (run from repo root):
#   docker build -t pembrook-skill-web_search:latest -f skills/web_search/Dockerfile .
#
# NOTE: This skill requires HTTPS egress to your SearXNG instance or
# api.search.brave.com. Run with --network=bridge or a custom network profile.

FROM dart:stable AS builder

WORKDIR /app

COPY skills/web_search/pubspec.yaml ./
COPY skills/web_search/pubspec.lock* ./
RUN dart pub get

COPY skills/web_search/bin ./bin
COPY skills/web_search/lib ./lib
RUN dart compile exe bin/main.dart -o /skill

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /skill /skill

ENTRYPOINT ["/skill"]
