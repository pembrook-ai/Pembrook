#!/usr/bin/env python3
"""Pembrook Real-Time Log Viewer — lightweight SSE server.

Streams Docker container logs to a browser via Server-Sent Events.
No dependencies beyond the Python 3 stdlib.

Usage:
    python tools/log_viewer/server.py [--port 9090] [--service agent,mcp_browser]

By default tails ALL compose services. Use --service to limit.
Then open http://localhost:9090 in your browser.
"""

import argparse
import html
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────

DEFAULT_PORT = 9090
DEFAULT_BIND = "0.0.0.0"  # Inside Docker, listen on all interfaces — the compose ports mapping
                           # (127.0.0.1:9090:9090) restricts access to the host loopback only.
DEFAULT_SERVICES: list[str] = []  # empty = all services

# Bearer token for authentication (set via LOG_VIEWER_TOKEN env var).
# If set, all requests must include 'Authorization: Bearer <token>' header.
AUTH_TOKEN: str = os.environ.get("LOG_VIEWER_TOKEN", "")

# COMPOSE_DIR: directory containing docker-compose.yml.
# In Docker the COMPOSE_DIR env var points to the mounted compose file.
# Locally, fall back to the repo root (two parents up from this script).
COMPOSE_DIR = Path(os.environ.get("COMPOSE_DIR", "")) if os.environ.get("COMPOSE_DIR") \
    else Path(__file__).resolve().parent.parent.parent

# Regex to extract the docker compose container name from log lines.
# Docker compose logs format: "pembrook-agent        | <content>"
_SERVICE_RE = re.compile(r'^(\S+)\s+\|\s+(.*)', re.DOTALL)

# Map container names to friendly service names.
def _container_to_service(container: str) -> str:
    """Strip 'pembrook-' prefix and normalise."""
    svc = container
    for prefix in ('pembrook-',):
        if svc.startswith(prefix):
            svc = svc[len(prefix):]
            break
    return svc


# ── SSE broadcaster ─────────────────────────────────────────────────────────

class LogBroadcaster:
    """Runs `docker compose logs -f` and broadcasts lines to SSE clients."""

    def __init__(self, services: list[str], compose_dir: Path):
        self.services = services  # empty list = all services
        self.compose_dir = compose_dir
        self._clients: list = []
        self._lock = threading.Lock()
        self._buffer: list[dict] = []  # last N events for new clients
        self._max_buffer = 500
        self._process = None

    def start(self):
        """Start tailing logs in a background thread."""
        t = threading.Thread(target=self._tail, daemon=True)
        t.start()

    def _tail(self):
        """Run docker compose logs -f and feed lines to clients."""
        while True:
            try:
                cmd = ["docker", "compose", "logs", "-f", "--tail=200",
                       "--timestamps"]
                cmd.extend(self.services)  # append service names (or none for all)
                self._process = subprocess.Popen(
                    cmd,
                    cwd=str(self.compose_dir),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
                for raw_line in self._process.stdout:
                    line = raw_line.rstrip("\n")
                    if not line:
                        continue
                    # Extract service name from docker compose prefix.
                    m = _SERVICE_RE.match(line)
                    if m:
                        service = _container_to_service(m.group(1))
                        content = m.group(2)
                    else:
                        service = "unknown"
                        content = line
                    self._broadcast(service, content)
                self._process.wait()
            except Exception as e:
                self._broadcast("log_viewer", f"Error: {e}")
            # If the process exits, wait and retry.
            svc_label = ', '.join(self.services) if self.services else 'all'
            time.sleep(3)
            self._broadcast("log_viewer", f"Reconnecting to {svc_label} logs...")

    def _broadcast(self, service: str, line: str):
        event = {"service": service, "line": line}
        with self._lock:
            self._buffer.append(event)
            if len(self._buffer) > self._max_buffer:
                self._buffer = self._buffer[-self._max_buffer:]
            dead = []
            for q in self._clients:
                try:
                    q.append(event)
                except Exception:
                    dead.append(q)
            for q in dead:
                self._clients.remove(q)

    def subscribe(self) -> list:
        """Return a client queue and backfill with buffered events."""
        q: list = []
        with self._lock:
            # Send buffered history first.
            q.extend(self._buffer)
            self._clients.append(q)
        return q

    def unsubscribe(self, q: list):
        with self._lock:
            if q in self._clients:
                self._clients.remove(q)


# ── HTTP handler ─────────────────────────────────────────────────────────────

INDEX_HTML = (Path(__file__).parent / "index.html").read_text

class LogViewerHandler(http.server.BaseHTTPRequestHandler):
    broadcaster: LogBroadcaster  # set by factory

    def log_message(self, format, *args):
        """Suppress default access log noise."""
        pass

    def handle(self):
        """Wrap handle() to suppress ConnectionResetError from abrupt disconnects."""
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, OSError):
            pass

    def _check_auth(self) -> bool:
        """SEC-002: Verify bearer token if AUTH_TOKEN is configured."""
        if not AUTH_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {AUTH_TOKEN}":
            return True
        self.send_response(401)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Unauthorized")
        return False

    def do_GET(self):
        if not self._check_auth():
            return
        if self.path == "/" or self.path == "/index.html":
            self._serve_html()
        elif self.path == "/events":
            self._serve_sse()
        elif self.path == "/api/services":
            self._serve_services()
        else:
            self.send_error(404)

    def _serve_html(self):
        content = INDEX_HTML()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content.encode())))
        self.end_headers()
        self.wfile.write(content.encode())

    def _serve_services(self):
        """Return list of running docker compose services."""
        try:
            result = subprocess.run(
                ["docker", "compose", "ps", "--format", "json"],
                cwd=str(COMPOSE_DIR),
                capture_output=True, text=True, timeout=10,
            )
            services = []
            for line in result.stdout.strip().splitlines():
                try:
                    obj = json.loads(line)
                    services.append({
                        "name": obj.get("Service", obj.get("Name", "?")),
                        "state": obj.get("State", "?"),
                        "status": obj.get("Status", "?"),
                    })
                except json.JSONDecodeError:
                    pass
            payload = json.dumps(services)
        except Exception as e:
            payload = json.dumps([{"name": "error", "state": str(e)}])
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload.encode())))
        self.end_headers()
        self.wfile.write(payload.encode())

    def _serve_sse(self):
        """Stream logs via Server-Sent Events."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        q = self.broadcaster.subscribe()
        try:
            while True:
                if q:
                    event = q.pop(0)
                    data = json.dumps(event)  # {"service": ..., "line": ...}
                    self.wfile.write(f"data: {data}\n\n".encode())
                    self.wfile.flush()
                else:
                    # Send keepalive comment every second.
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.broadcaster.unsubscribe(q)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Pembrook Log Viewer")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--service", default="",
                        help="Comma-separated Docker Compose services to tail (default: all)")
    args = parser.parse_args()

    services = [s.strip() for s in args.service.split(",") if s.strip()] if args.service else DEFAULT_SERVICES
    broadcaster = LogBroadcaster(services, COMPOSE_DIR)
    broadcaster.start()

    handler = type("H", (LogViewerHandler,), {"broadcaster": broadcaster})
    bind_addr = os.environ.get("LOG_VIEWER_BIND", DEFAULT_BIND)
    server = http.server.ThreadingHTTPServer((bind_addr, args.port), handler)
    svc_label = ', '.join(services) if services else 'all services'
    if not AUTH_TOKEN:
        print(
            "FATAL: LOG_VIEWER_TOKEN is not set.\n"
            "The log viewer streams all container logs and must be protected.\n"
            "Set LOG_VIEWER_TOKEN to a strong random secret, e.g.:\n"
            "  openssl rand -hex 32\n"
            "Then add it to your .env file: LOG_VIEWER_TOKEN=<value>\n"
            "Refusing to start unauthenticated.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"🔍 Pembrook Log Viewer — http://{bind_addr}:{args.port}")
    print(f"   Streaming: docker compose logs -f {svc_label}")
    print(f"   Compose dir: {COMPOSE_DIR}")
    print(f"   Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping log viewer.")
        server.shutdown()


if __name__ == "__main__":
    main()
