# SafeClaw Email Skill
# Multi-stage build: compile to native binary, then copy into minimal runtime.
#
# Build:
#   docker build -t safeclaw-skill-email:latest -f skills/email/Dockerfile .
#
# The resulting image is invoked by SandboxManager as:
#   docker run --rm --network=none ... safeclaw-skill-email:latest
#
# NOTE: --network=none is the default sandbox.
# The email skill REQUIRES network access (SMTP + IMAP).
# Start the container with --network=bridge or a custom network profile.

# ── Stage 1: compile ──────────────────────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /app

# Copy pubspec files and fetch dependencies (layer-cached when unchanged).
COPY skills/email/pubspec.yaml skills/email/pubspec.lock* ./
RUN dart pub get

# Copy source and compile to a self-contained native binary.
COPY skills/email/ .
RUN dart compile exe bin/main.dart -o /skill

# ── Stage 2: minimal runtime ──────────────────────────────────────────────────
FROM debian:bookworm-slim

# Install CA certificates so SMTP/IMAP TLS handshakes succeed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /skill /skill

# The SandboxManager writes a JSON line to stdin and reads the response.
ENTRYPOINT ["/skill"]
