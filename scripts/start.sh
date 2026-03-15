#!/usr/bin/env bash
# start.sh — Build all SafeClaw images and start (or refresh) the stack.
#
# Safe to run against an already-running stack — docker compose up --build -d
# only restarts a container when its image has actually changed.  Use
# --force-recreate to unconditionally restart all containers.
#
# Usage:
#   bash scripts/start.sh [OPTIONS]
#
# Options:
#   --bundled-ollama   Start Ollama inside Docker instead of using host Ollama.
#   --gpu              Combine with --bundled-ollama for NVIDIA GPU support
#                      (Linux + NVIDIA only; adds docker-compose.gpu.yml overlay).
#   --no-skills        Skip building the skill images (use existing cached images).
#   --force-recreate   Force-restart all containers even if images are unchanged.
#   --help             Show this help and exit.
#
# What this script does:
#   1. Verifies that .env exists (or exits with a pointer to setup.sh).
#   2. Builds each skill image from its own directory as the build context
#      (required because the root .dockerignore excludes skills/).
#   3. Runs docker compose up --build -d (rebuilds the agent image if changed,
#      restarts any container whose image changed).
#   4. Prints a short status summary.
#
# Skill images built (tagged for use by SandboxManager at runtime):
#   safeclaw-skill-email:latest
#   safeclaw-skill-calendar:latest
#   safeclaw-skill-web-search:latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${NC}"; }

# ── Flags ─────────────────────────────────────────────────────────────────────
BUNDLED_OLLAMA=false
GPU=false
BUILD_SKILLS=true
FORCE_RECREATE=false

for arg in "$@"; do
  case "$arg" in
    --bundled-ollama)  BUNDLED_OLLAMA=true ;;
    --gpu)             GPU=true ;;
    --no-skills)       BUILD_SKILLS=false ;;
    --force-recreate)  FORCE_RECREATE=true ;;
    --help|-h)
      sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,2\}//; p }' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg  (use --help for usage)"
      exit 1
      ;;
  esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        SafeClaw  —  Start All Services       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
header "Preflight checks"

if [[ ! -f "$ENV_FILE" ]]; then
  error ".env not found.  Run setup first:"
  echo ""
  echo "    bash scripts/setup.sh"
  echo ""
  exit 1
fi
success ".env found"

if ! command -v docker &>/dev/null; then
  error "docker not found on PATH."
  exit 1
fi
success "Docker found"

if ! docker compose version &>/dev/null 2>&1; then
  error "Docker Compose (v2) not found.  Install Docker Desktop or the compose plugin."
  exit 1
fi
success "Docker Compose found"

# Warn if host Ollama is not running and --bundled-ollama was not requested.
if [[ "$BUNDLED_OLLAMA" == "false" ]]; then
  if ! curl -sf http://localhost:11434 &>/dev/null; then
    warn "Ollama does not appear to be running on localhost:11434."
    warn "Start it with:  ollama serve"
    warn "Or rerun with:  bash scripts/start.sh --bundled-ollama"
    echo ""
  else
    success "Host Ollama running on port 11434"
  fi
fi

cd "$PROJECT_ROOT"

# ── Build skill images ────────────────────────────────────────────────────────
# Each skill is built from its OWN directory as the Docker build context.
# This is required because the root .dockerignore excludes the skills/ tree.
if [[ "$BUILD_SKILLS" == "true" ]]; then
  header "Building skill images"

  build_skill() {
    local name="$1"          # human-readable label
    local tag="$2"           # docker image tag
    local dir="$3"           # path to skill directory (used as build context)

    if [[ ! -d "$dir" ]]; then
      warn "Skill directory not found, skipping: $dir"
      return
    fi

    info "Building $name  →  $tag"
    # Build context = skill directory; Dockerfile must sit inside that directory.
    docker build -t "$tag" "$dir"
    success "$name image ready: $tag"
  }

  build_skill "Email skill"      "safeclaw-skill-email:latest"      "$PROJECT_ROOT/skills/email"
  build_skill "Calendar skill"   "safeclaw-skill-calendar:latest"   "$PROJECT_ROOT/skills/calendar"
  build_skill "Web Search skill" "safeclaw-skill-web-search:latest" "$PROJECT_ROOT/skills/web_search"
else
  info "Skipping skill image builds (--no-skills)"
fi

# ── Start the compose stack ───────────────────────────────────────────────────
header "Starting SafeClaw stack"

COMPOSE_ARGS=("--build" "-d")
[[ "$FORCE_RECREATE" == "true" ]] && COMPOSE_ARGS+=("--force-recreate")
COMPOSE_FLAGS=()

if [[ "$BUNDLED_OLLAMA" == "true" ]]; then
  COMPOSE_FLAGS+=("--profile" "bundled-ollama")
  info "Profile: bundled-ollama (Ollama runs inside Docker)"
fi

if [[ "$GPU" == "true" ]]; then
  if [[ "$BUNDLED_OLLAMA" == "false" ]]; then
    warn "--gpu has no effect without --bundled-ollama; ignoring."
  else
    COMPOSE_FLAGS+=("-f" "$PROJECT_ROOT/docker-compose.yml" "-f" "$PROJECT_ROOT/docker-compose.gpu.yml")
    info "Overlay: docker-compose.gpu.yml (NVIDIA GPU)"
  fi
fi

info "Running: docker compose ${COMPOSE_FLAGS[*]+"${COMPOSE_FLAGS[*]}"} up ${COMPOSE_ARGS[*]}"
docker compose ${COMPOSE_FLAGS[@]+"${COMPOSE_FLAGS[@]}"} up "${COMPOSE_ARGS[@]}"

# ── Status summary ────────────────────────────────────────────────────────────
header "Stack status"

docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Service}}"

echo ""
echo -e "${GREEN}SafeClaw is running.${NC}"
echo ""
echo -e "  Tail agent logs :  ${CYAN}docker compose logs -f agent${NC}"
echo -e "  Stop everything :  ${CYAN}docker compose down${NC}"
echo ""
echo -e "  Run the Flutter app:"
echo -e "     ${CYAN}cd app && flutter run${NC}"
echo ""
