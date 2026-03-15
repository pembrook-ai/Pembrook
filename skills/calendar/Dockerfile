# Pembrook Calendar Skill
# Multi-stage build: compile to native binary, then copy into minimal runtime.
#
# Build (run from repo root):
#   docker build -t pembrook-skill-calendar:latest skills/calendar/
#
# NOTE: This skill requires HTTPS egress to www.googleapis.com.
# Run with --network=bridge or a custom network profile.

FROM dart:stable AS builder

WORKDIR /app

COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/main.dart -o /skill

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /skill /skill

ENTRYPOINT ["/skill"]
