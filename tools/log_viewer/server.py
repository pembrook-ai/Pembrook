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

    def _list_containers(self) -> list[str]:
        """Return running container names (filtered to self.services if set)."""
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.Names}}"],
                capture_output=True, text=True, timeout=10,
            )
            names = [n.strip() for n in result.stdout.splitlines() if n.strip()]
            if self.services:
                # Filter to containers whose name contains any of the service names.
                names = [n for n in names if any(s in n for s in self.services)]
            return names
        except Exception:
            return []

    def _tail_container(self, container: str):
        """Tail a single container in its own thread."""
        service = _container_to_service(container)
        while True:
            try:
                proc = subprocess.Popen(
                    ["docker", "logs", "--follow", "--tail=200", "--timestamps", container],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
                for raw_line in proc.stdout:
                    line = raw_line.rstrip("\n")
                    if line:
                        self._broadcast(service, line)
                proc.wait()
            except Exception as e:
                self._broadcast(service, f"[log_viewer] error tailing {container}: {e}")
            time.sleep(5)
            self._broadcast(service, f"[log_viewer] reconnecting to {container}...")

    def _tail(self):
        """Discover containers and start a tail thread per container."""
        while True:
            containers = self._list_containers()
            if containers:
                for c in containers:
                    t = threading.Thread(target=self._tail_container, args=(c,), daemon=True)
                    t.start()
                return  # threads run indefinitely; this discovery loop exits
            self._broadcast("log_viewer", "Waiting for containers to start...")
            time.sleep(5)

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
        """SEC-002: Verify bearer token if AUTH_TOKEN is configured.

        Browser requests are checked for a token cookie first (set after the
        login form is submitted), then the Authorization header (for API/curl).
        The login page itself (/login and /login POST) are always served.
        """
        if not AUTH_TOKEN:
            return True

        # Allow the login page through unauthenticated.
        if self.path in ("/login",):
            return True

        # Check cookie token (set by the login form).
        cookies = self.headers.get("Cookie", "")
        for part in cookies.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "lv_token" and v.strip() == AUTH_TOKEN:
                return True

        # Check Authorization: Bearer <token> header (curl / API).
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {AUTH_TOKEN}":
            return True

        # Not authenticated — redirect to login page.
        self.send_response(302)
        self.send_header("Location", "/login")
        self.end_headers()
        return False

    def do_POST(self):
        """Handle login form submission."""
        if self.path == "/login":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            token = ""
            for part in body.split("&"):
                k, _, v = part.partition("=")
                if k == "token":
                    from urllib.parse import unquote_plus
                    token = unquote_plus(v)
            if token == AUTH_TOKEN:
                self.send_response(302)
                self.send_header("Set-Cookie", f"lv_token={AUTH_TOKEN}; Path=/; HttpOnly; SameSite=Strict")
                self.send_header("Location", "/")
                self.end_headers()
            else:
                self._serve_login(error=True)
        else:
            self.send_error(405)

    def _serve_login(self, error: bool = False) -> None:
        error_msg = '<p style="color:#f85149;margin-bottom:12px">Invalid token — try again.</p>' if error else ""
        page = f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Pembrook Log Viewer — Login</title>
<style>
  body{{background:#0d1117;color:#c9d1d9;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}}
  form{{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:32px;min-width:320px;text-align:center}}
  h1{{color:#58a6ff;margin-bottom:24px;font-size:18px}}
  input{{width:100%;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;padding:10px;border-radius:6px;font-family:monospace;font-size:14px;box-sizing:border-box;margin-bottom:16px}}
  button{{width:100%;background:#238636;color:#fff;border:none;padding:10px;border-radius:6px;font-size:14px;cursor:pointer}}
  button:hover{{background:#2ea043}}
</style></head>
<body><form method="POST" action="/login">
  <h1>Pembrook Log Viewer</h1>
  {error_msg}
  <input type="password" name="token" placeholder="Enter LOG_VIEWER_TOKEN" autofocus>
  <button type="submit">Sign in</button>
</form></body></html>"""
        content = page.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        if self.path == "/login":
            self._serve_login()
            return
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
        """Return list of running docker compose services using docker ps."""
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"],
                capture_output=True, text=True, timeout=10,
            )
            services = []
            for line in result.stdout.strip().splitlines():
                parts = line.split("\t", 1)
                name = parts[0].strip() if parts else "?"
                status = parts[1].strip() if len(parts) > 1 else "?"
                services.append({"name": _container_to_service(name), "state": "running", "status": status})
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
