#!/usr/bin/env bash
# setup.sh — Interactive first-run setup wizard for SafeClaw
#
# Usage: bash scripts/setup.sh [--non-interactive]
#
# What it does:
#   1. Checks prerequisites (Dart SDK, Docker + Compose, Ollama)
#   2. Prompts for your atSigns and verifies .atKeys files exist
#   3. Writes a .env file in the project root
#   4. Runs dart run agent/bin/init_config.dart to write AtKeys to your atServer
#   5. Prints docker compose start instructions
#
# Prerequisites:
#   • Dart SDK 3.6+ on PATH
#   • Docker + Docker Compose plugin (docker compose v2)
#   • Ollama running locally (or docker-compose.yml brings it up)
#   • At least TWO free atSigns from https://my.atsign.com/dashboard
#       @agent  — the backend daemon  (minimum)
#       @owner  — the Flutter app / CLI  (minimum)
#       @bridges — all bridge processes share this one (needed for WhatsApp / Telegram / Discord / Slack)
#   • .atKeys files in ~/.atsign/keys/ (the standard atSign location)
#       e.g.  ~/.atsign/keys/@myagent_key.atKeys
#             ~/.atsign/keys/@myowner_key.atKeys
#
# Re-running this script is safe — it overwrites the .env and AtKeys with
# whatever new values you provide.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
KEYS_DIR="${HOME}/.atsign/keys"
NON_INTERACTIVE=false

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

# ── Parse flags ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=true ;;
    --help|-h)
      echo "Usage: bash scripts/setup.sh [--non-interactive]"
      echo ""
      echo "  --non-interactive   Read values from environment variables instead of prompting."
      echo "                      Required env vars: AGENT_AT_SIGN, OWNER_AT_SIGN,"
      echo "                      AGENT_KEYS_PATH, OWNER_KEYS_PATH"
      echo "                      Optional: BRIDGES_AT_SIGN, BRIDGES_KEYS_PATH,"
      echo "                                ALLOWED_USERS, OLLAMA_MODEL"
      exit 0
      ;;
  esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       SafeClaw  —  First-Run Setup           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
header "Step 1: Checking prerequisites"

check_cmd() {
  local cmd="$1"
  local name="${2:-$cmd}"
  if command -v "$cmd" &>/dev/null; then
    success "$name found: $(command -v "$cmd")"
  else
    error "$name not found. Please install it first."
    echo ""
    case "$name" in
      "Dart SDK") echo "  Install: https://dart.dev/get-dart" ;;
      "Docker")   echo "  Install: https://docs.docker.com/get-docker/" ;;
    esac
    exit 1
  fi
}

check_cmd dart "Dart SDK"
check_cmd docker "Docker"

# Check docker compose (v2 — 'docker compose' subcommand)
if docker compose version &>/dev/null 2>&1; then
  success "Docker Compose found (v2)"
else
  error "Docker Compose not found. Please install Docker Desktop or the compose plugin."
  exit 1
fi

# Dart version check ≥ 3.6
DART_VERSION=$(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
DART_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)
DART_MINOR=$(echo "$DART_VERSION" | cut -d. -f2)
if [[ "$DART_MAJOR" -lt 3 ]] || ( [[ "$DART_MAJOR" -eq 3 ]] && [[ "$DART_MINOR" -lt 6 ]] ); then
  error "Dart SDK 3.6+ is required (found $DART_VERSION)"
  exit 1
fi
success "Dart $DART_VERSION"

# Ensure standard atSign keys directory exists
mkdir -p "$KEYS_DIR"

# ── Step 2: Collect atSign configuration ─────────────────────────────────────
header "Step 2: atSign configuration"
echo ""
echo "SafeClaw requires at least TWO atSigns:"
echo "  • @agent  — the daemon that runs on your server / in Docker"
echo "  • @owner  — your Flutter app / CLI identity"
echo ""
echo "If you want messaging bridges (WhatsApp, Telegram, Discord, Slack),"
echo "you need a THIRD atSign:"
echo "  • @bridges — all four bridge processes share this one atSign"
echo ""
echo "Register free atSigns at: https://my.atsign.com/dashboard"
echo "Then download the .atKeys files and place them in: ~/.atsign/keys/"
echo ""

prompt_or_env() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    local val="${!var_name:-}"
    if [[ -z "$val" && -z "$default_value" ]]; then
      error "Non-interactive mode: env var $var_name is required but not set."
      exit 1
    fi
    echo "${val:-$default_value}"
  else
    local display_default=""
    [[ -n "$default_value" ]] && display_default=" [$default_value]"
    read -rp "$(echo -e "${CYAN}${prompt_text}${display_default}${NC}: ")" input
    echo "${input:-$default_value}"
  fi
}

# Agent atSign
AGENT_AT_SIGN=$(prompt_or_env AGENT_AT_SIGN "Agent atSign (e.g. @myagent)")
[[ "$AGENT_AT_SIGN" != @* ]] && AGENT_AT_SIGN="@$AGENT_AT_SIGN"

# Owner atSign
OWNER_AT_SIGN=$(prompt_or_env OWNER_AT_SIGN "Owner atSign (e.g. @myowner)")
[[ "$OWNER_AT_SIGN" != @* ]] && OWNER_AT_SIGN="@$OWNER_AT_SIGN"

# Agent .atKeys file path
DEFAULT_AGENT_KEYS="$KEYS_DIR/${AGENT_AT_SIGN}_key.atKeys"
AGENT_KEYS_PATH=$(prompt_or_env AGENT_KEYS_PATH "Agent .atKeys file path" "$DEFAULT_AGENT_KEYS")

if [[ ! -f "$AGENT_KEYS_PATH" ]]; then
  error "Agent .atKeys file not found: $AGENT_KEYS_PATH"
  echo ""
  echo "Download your .atKeys file from https://my.atsign.com/dashboard"
  echo "and place it at: $AGENT_KEYS_PATH"
  exit 1
fi
success "Agent .atKeys found"

# Bridges atSign (optional)
BRIDGES_AT_SIGN=$(prompt_or_env BRIDGES_AT_SIGN "Bridges atSign (leave blank to skip bridges)" "")
if [[ -n "$BRIDGES_AT_SIGN" ]]; then
  [[ "$BRIDGES_AT_SIGN" != @* ]] && BRIDGES_AT_SIGN="@$BRIDGES_AT_SIGN"
  DEFAULT_BRIDGES_KEYS="$KEYS_DIR/${BRIDGES_AT_SIGN}_key.atKeys"
  BRIDGES_KEYS_PATH=$(prompt_or_env BRIDGES_KEYS_PATH "Bridges .atKeys file path" "$DEFAULT_BRIDGES_KEYS")
  if [[ ! -f "$BRIDGES_KEYS_PATH" ]]; then
    error "Bridges .atKeys file not found: $BRIDGES_KEYS_PATH"
    exit 1
  fi
  success "Bridges .atKeys found"
else
  BRIDGES_KEYS_PATH=""
fi

# Ollama model
OLLAMA_MODEL=$(prompt_or_env OLLAMA_MODEL "Ollama model name" "llama3.2")

# Extra allowed users (optional)
ALLOWED_USERS_EXTRA=$(prompt_or_env ALLOWED_USERS \
  "Extra allowed atSigns (comma-separated, leave blank for none)" "")

# Build canonical allowed users string
ALL_ALLOWED="$OWNER_AT_SIGN"
[[ -n "$BRIDGES_AT_SIGN" ]] && ALL_ALLOWED="$ALL_ALLOWED,$BRIDGES_AT_SIGN"
[[ -n "$ALLOWED_USERS_EXTRA" ]] && ALL_ALLOWED="$ALL_ALLOWED,$ALLOWED_USERS_EXTRA"

# ── Step 3: Write .env ────────────────────────────────────────────────────────
header "Step 3: Writing .env"

AGENT_KEY_FILE="$(basename "$AGENT_KEYS_PATH")"
BRIDGES_KEY_FILE=""
[[ -n "$BRIDGES_KEYS_PATH" ]] && BRIDGES_KEY_FILE="$(basename "$BRIDGES_KEYS_PATH")"

cat > "$ENV_FILE" <<EOF
# SafeClaw environment configuration — generated by scripts/setup.sh
# Edit this file to change settings, then re-run docker compose up --build

# ── Core atSigns ────────────────────────────────────────────────────────────
AGENT_AT_SIGN=$AGENT_AT_SIGN
OWNER_AT_SIGN=$OWNER_AT_SIGN
$([ -n "$BRIDGES_AT_SIGN" ] && echo "BRIDGES_AT_SIGN=$BRIDGES_AT_SIGN" || echo "# BRIDGES_AT_SIGN=")

# ── Keys directory and file names ───────────────────────────────────────────
# docker-compose mounts this directory read-only as /keys inside containers.
# Default: ~/.atsign/keys  (the standard atSign key location)
KEYS_DIR=$KEYS_DIR
AGENT_KEY_FILE=$AGENT_KEY_FILE
$([ -n "$BRIDGES_KEY_FILE" ] && echo "BRIDGES_KEY_FILE=$BRIDGES_KEY_FILE" || echo "# BRIDGES_KEY_FILE=")

# ── Access control ───────────────────────────────────────────────────────────
# Comma-separated list of atSigns allowed to send commands to the agent.
# This is the startup fallback; once init_config.dart has run, the atServer
# AtKey (settings.allowed_users) takes precedence.
ALLOWED_USERS=$ALL_ALLOWED

# ── LLM ─────────────────────────────────────────────────────────────────────
OLLAMA_MODEL=$OLLAMA_MODEL
# Ollama is started by docker-compose; the agent connects to http://ollama:11434
# OLLAMA_BASE_URL is always set to http://ollama:11434 inside docker-compose.

# ── Optional external LLM keys (leave blank to use Ollama only) ─────────────
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
EOF

success ".env written to $ENV_FILE"

# ── Step 4: Verify .atKeys files are in ~/.atsign/keys/ ────────────────────────
header "Step 4: Verifying keys directory"

# If the atKeys file is already in ~/.atsign/keys, nothing to do.
# If it's elsewhere, offer to copy.
copy_if_needed() {
  local src="$1"
  local dest_dir="$KEYS_DIR"
  local dest="$dest_dir/$(basename "$src")"
  if [[ "$src" == "$dest" ]]; then
    success "Key already in ~/.atsign/keys/: $(basename "$src")"
    return
  fi
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    cp "$src" "$dest"
    success "Copied $(basename "$src") → ~/.atsign/keys/"
  else
    read -rp "$(echo -e "${CYAN}Copy $(basename "$src") to ~/.atsign/keys/? [Y/n]${NC}: ")" yn
    case "${yn,,}" in
      n|no) info "Skipped. Make sure $dest exists before running docker compose." ;;
      *)
        cp "$src" "$dest"
        success "Copied $(basename "$src") → keys/"
        ;;
    esac
  fi
}

copy_if_needed "$AGENT_KEYS_PATH"
[[ -n "$BRIDGES_KEYS_PATH" ]] && copy_if_needed "$BRIDGES_KEYS_PATH"

# ── Step 5: Write AtKeys to atServer ──────────────────────────────────────────
header "Step 5: Writing configuration AtKeys to $AGENT_AT_SIGN's atServer"
echo ""
echo "This authenticates as $AGENT_AT_SIGN and writes settings AtKeys."
echo "(Requires outbound internet access to the atPlatform root server)"
echo ""

# Build init_config arguments
INIT_ARGS=(
  "--atsign" "$AGENT_AT_SIGN"
  "--key-file" "$AGENT_KEYS_PATH"
  "--owner" "$OWNER_AT_SIGN"
  "--ollama-model" "$OLLAMA_MODEL"
)
[[ -n "$BRIDGES_AT_SIGN" ]] && INIT_ARGS+=("--bridges-atsign" "$BRIDGES_AT_SIGN")
[[ -n "$ALLOWED_USERS_EXTRA" ]] && INIT_ARGS+=("--allowed-users" "$ALLOWED_USERS_EXTRA")

cd "$PROJECT_ROOT/agent"
dart pub get

echo -e "${CYAN}Running:${NC} dart run bin/init_config.dart ${INIT_ARGS[*]}"
echo ""
dart run bin/init_config.dart "${INIT_ARGS[@]}"

cd "$PROJECT_ROOT"

# ── Step 6: Summary ───────────────────────────────────────────────────────────
header "Setup complete!"
echo ""
echo -e "${GREEN}Configuration summary:${NC}"
echo "  Agent atSign  : $AGENT_AT_SIGN"
echo "  Owner atSign  : $OWNER_AT_SIGN"
[[ -n "$BRIDGES_AT_SIGN" ]] && echo "  Bridges atSign: $BRIDGES_AT_SIGN"
echo "  AllowList     : $ALL_ALLOWED"
echo "  Ollama model  : $OLLAMA_MODEL"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  1. Start the backend:"
echo -e "     ${CYAN}docker compose up --build${NC}"
echo ""
echo "  2. Open the Flutter app in the app/ directory:"
echo -e "     ${CYAN}cd app && flutter run${NC}"
echo ""
echo "  3. Authenticate in the app as: ${OWNER_AT_SIGN}"
echo ""
if [[ -n "$BRIDGES_AT_SIGN" ]]; then
  echo "  4. Configure a bridge (e.g. WhatsApp) in the Bridges screen,"
  echo "     pointing it to use atSign: ${BRIDGES_AT_SIGN}"
  echo ""
fi
echo "  For full documentation: see GETTING_STARTED.md"
echo ""
