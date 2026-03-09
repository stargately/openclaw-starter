#!/usr/bin/env bash
# deploy.sh — One-click OpenClaw setup with custom Anthropic endpoint + Telegram
#
# Required env vars:
#   ANTHROPIC_BASE_URL     Custom Anthropic base URL (trailing /v1 is stripped automatically)
#   TELEGRAM_BOT_TOKEN     Telegram bot token
#
# Optional env vars:
#   OPENCLAW_GATEWAY_TOKEN                    Gateway token (auto-generated if unset)
#   OPENCLAW_CONFIG_DIR                       Config directory (default: ./data/config)
#   OPENCLAW_WORKSPACE_DIR                    Workspace directory (default: ./data/workspace)
#   OPENCLAW_IMAGE                            Docker image (default: ghcr.io/openclaw/openclaw:2026.3.1)
#   OPENCLAW_GATEWAY_PORT                     Gateway port (default: 18789)
#   OPENCLAW_GATEWAY_CONTROL_UI_ALLOWED_ORIGINS  Allowed origins for control UI (default: https://*.onblockeden.xyz)

set -euo pipefail

# ── Load .env if present ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # Export each non-comment, non-empty line; skip lines already set in environment
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${BOLD}[deploy]${RESET} $*"; }
success() { echo -e "${GREEN}[ok]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET} $*"; }
fail()    { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── Step 1: Validate inputs ───────────────────────────────────────────────────
info "Validating inputs..."

for cmd in docker envsubst openssl curl; do
  command -v "$cmd" &>/dev/null || fail "Required tool not found: $cmd"
done
docker compose version &>/dev/null || fail "Docker Compose v2 not found (need 'docker compose', not 'docker-compose')"

[[ -n "${ANTHROPIC_BASE_URL:-}"  ]] || fail "ANTHROPIC_BASE_URL is required"
[[ -n "${TELEGRAM_BOT_TOKEN:-}"  ]] || fail "TELEGRAM_BOT_TOKEN is required"

# Strip trailing /v1 (with or without trailing slash) — openclaw appends it internally
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL%/v1/}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL%/v1}"

if ! echo "$ANTHROPIC_BASE_URL" | grep -qE '^https?://'; then
  fail "ANTHROPIC_BASE_URL must start with http:// or https://  (got: $ANTHROPIC_BASE_URL)"
fi

OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-./data/config}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-./data/config/workspace}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:2026.3.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_GATEWAY_CONTROL_UI_ALLOWED_ORIGINS="${OPENCLAW_GATEWAY_CONTROL_UI_ALLOWED_ORIGINS:-https://*.onblockeden.xyz}"

success "Inputs look valid"
info "  Base URL : $ANTHROPIC_BASE_URL"
info "  Config   : $OPENCLAW_CONFIG_DIR"
info "  Image    : $OPENCLAW_IMAGE"
info "  Port     : $OPENCLAW_GATEWAY_PORT"

CONFIG_FILE="$OPENCLAW_CONFIG_DIR/openclaw.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  # ── Step 2: Generate config from template ───────────────────────────────────
  info "Generating config..."

  # Auto-generate gateway token if unset
  OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"
  [[ ${#OPENCLAW_GATEWAY_TOKEN} -ge 16 ]] || fail "OPENCLAW_GATEWAY_TOKEN is too short (min 16 chars)"

  TEMPLATE="$SCRIPT_DIR/template.json"
  [[ -f "$TEMPLATE" ]] || fail "template.json not found at $TEMPLATE"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  export ANTHROPIC_BASE_URL OPENCLAW_GATEWAY_TOKEN TELEGRAM_BOT_TOKEN OPENCLAW_GATEWAY_CONTROL_UI_ALLOWED_ORIGINS
  envsubst < "$TEMPLATE" > "$CONFIG_FILE"
  success "Config generated from template.json → $CONFIG_FILE"

  # ── Step 3: Prepare directories ─────────────────────────────────────────────
  info "Preparing directories..."

  mkdir -p "$OPENCLAW_CONFIG_DIR" "$OPENCLAW_WORKSPACE_DIR"
  mkdir -p "$OPENCLAW_CONFIG_DIR/identity"
  mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/agent"
  mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/sessions"

  success "Directories ready"

  # ── Step 4: Fix data-directory permissions ───────────────────────────────────
  info "Fixing data-directory permissions..."
  # Ensure bind-mounted dirs are writable by the container's `node` user (uid 1000).
  # Use -xdev to restrict chown to the config-dir mount only.
  docker run --rm --user root \
    -v "$OPENCLAW_CONFIG_DIR:/home/node/.openclaw" \
    -v "$OPENCLAW_WORKSPACE_DIR:/home/node/.openclaw/workspace" \
    --entrypoint sh "$OPENCLAW_IMAGE" -c \
    'find /home/node/.openclaw -xdev -exec chown node:node {} +; \
     [ -d /home/node/.openclaw/workspace/.openclaw ] && chown -R node:node /home/node/.openclaw/workspace/.openclaw || true'
  success "Permissions fixed"
else
  info "Config already exists at $CONFIG_FILE, skipping steps 2-4"
fi

# ── Step 5: Start the gateway ─────────────────────────────────────────────────
info "Starting gateway..."

export OPENCLAW_IMAGE
[[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]] && export OPENCLAW_GATEWAY_TOKEN
export OPENCLAW_CONFIG_DIR
export OPENCLAW_WORKSPACE_DIR
export OPENCLAW_GATEWAY_PORT

docker compose up -d --build

# Wait for gateway to become healthy
info "Waiting for gateway to be ready..."
DEADLINE=$(( $(date +%s) + 30 ))
until curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz" >/dev/null 2>&1; do
  if [[ $(date +%s) -ge $DEADLINE ]]; then
    warn "Gateway did not respond within 30s. Check logs with: docker compose logs openclaw-gateway"
    break
  fi
  sleep 1
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Deployment complete${RESET}"
echo "  Gateway URL   : http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}"
[[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]] && echo "  Gateway token : $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Next steps:"
echo "  Open http://127.0.0.1:${OPENCLAW_GATEWAY_PORT} and paste the token into Settings."
echo "  Check status : docker compose logs -f openclaw-gateway"
echo "  Health check : curl -fsS http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz"
