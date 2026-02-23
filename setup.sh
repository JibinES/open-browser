#!/usr/bin/env bash
set -euo pipefail

# ============================================
# OpenClaw + Ollama — One-Click Setup Script
# ============================================
# Just run: ./setup.sh
# Everything else is automatic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

header() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
}

# ---- Load .env ----
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        cp .env.example .env
        warn ".env not found — created from .env.example"
        warn "Edit .env with your Telegram token/user ID if needed."
    else
        err ".env file not found and no .env.example to copy from!"
        exit 1
    fi
fi
set -a
source .env
set +a
log "Loaded .env configuration"

# ---- Auto-generate gateway token if empty ----
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
    # Persist it into .env so it survives restarts
    if grep -q '^OPENCLAW_GATEWAY_TOKEN=' .env; then
        sed -i "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}|" .env
    else
        echo "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" >> .env
    fi
    export OPENCLAW_GATEWAY_TOKEN
    log "Generated gateway token (saved to .env)"
fi

# ---- Pre-flight checks ----
header "Pre-flight Checks"

# Docker
if ! command -v docker &>/dev/null; then
    err "Docker is not installed or not in PATH."
    exit 1
fi
log "Docker found: $(docker --version | head -1)"

# Docker Compose
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
    log "Docker Compose found: $(docker compose version --short 2>/dev/null || echo 'v2+')"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
    log "Docker Compose found (standalone)"
else
    err "Docker Compose not found."
    exit 1
fi

# NVIDIA GPU
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    log "GPU detected: ${GPU_NAME} (${GPU_VRAM} MB VRAM)"
else
    warn "nvidia-smi not found. GPU acceleration may not work."
fi

# NVIDIA Container Toolkit
if docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi &>/dev/null 2>&1; then
    log "NVIDIA Container Toolkit working"
else
    warn "NVIDIA Container Toolkit may not be configured."
    warn "GPU passthrough might fail. See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
fi

# ---- Find Chrome ----
header "Chrome Detection"

if [[ -n "${CHROME_PATH:-}" ]]; then
    if [[ -x "$CHROME_PATH" ]]; then
        log "Using Chrome from .env: $CHROME_PATH"
    else
        err "CHROME_PATH in .env is not executable: $CHROME_PATH"
        exit 1
    fi
else
    # Auto-detect Chrome
    CHROME_CANDIDATES=(
        "google-chrome"
        "google-chrome-stable"
        "chromium-browser"
        "chromium"
        "/usr/bin/google-chrome"
        "/usr/bin/google-chrome-stable"
        "/usr/bin/chromium-browser"
        "/usr/bin/chromium"
        "/snap/bin/chromium"
        "/opt/google/chrome/google-chrome"
    )

    CHROME_PATH=""
    for candidate in "${CHROME_CANDIDATES[@]}"; do
        if command -v "$candidate" &>/dev/null 2>&1 || [[ -x "$candidate" ]]; then
            CHROME_PATH="$candidate"
            break
        fi
    done

    if [[ -z "$CHROME_PATH" ]]; then
        err "Chrome/Chromium not found on this system!"
        err "Set CHROME_PATH in .env to your Chrome binary path."
        exit 1
    fi
    log "Auto-detected Chrome: $CHROME_PATH"
fi

CHROME_VERSION=$("$CHROME_PATH" --version 2>/dev/null || echo "unknown")
log "Chrome version: $CHROME_VERSION"

# ---- Kill existing Chrome CDP (if any) ----
CDP_PORT="${CHROME_CDP_PORT:-9222}"

if lsof -i :"$CDP_PORT" &>/dev/null 2>&1; then
    warn "Port $CDP_PORT is already in use."
    EXISTING_PID=$(lsof -ti :"$CDP_PORT" 2>/dev/null | head -1)
    if [[ -n "$EXISTING_PID" ]]; then
        EXISTING_CMD=$(ps -p "$EXISTING_PID" -o comm= 2>/dev/null || echo "unknown")
        warn "Process: $EXISTING_CMD (PID: $EXISTING_PID)"
        read -rp "Kill it and continue? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            kill "$EXISTING_PID" 2>/dev/null || true
            sleep 2
            log "Killed process on port $CDP_PORT"
        else
            err "Cannot continue with port $CDP_PORT in use."
            exit 1
        fi
    fi
fi

# ---- Stop existing containers ----
header "Container Setup"

if $COMPOSE_CMD ps -q 2>/dev/null | grep -q .; then
    info "Stopping existing containers..."
    $COMPOSE_CMD down 2>/dev/null || true
    log "Old containers stopped"
fi

# ---- Pull images ----
info "Pulling Docker images (this may take a while on first run)..."
$COMPOSE_CMD pull
log "Images pulled"

# ---- Start Ollama ----
header "Starting Ollama"

info "Starting Ollama container..."
$COMPOSE_CMD up -d ollama
log "Ollama container started"

# Wait for Ollama to be ready
info "Waiting for Ollama API to be ready..."
RETRIES=0
MAX_RETRIES=30
until curl -sf http://127.0.0.1:${OLLAMA_PORT:-11434}/api/tags &>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge $MAX_RETRIES ]]; then
        err "Ollama failed to start after ${MAX_RETRIES} attempts."
        err "Check logs: docker logs openclaw-ollama"
        exit 1
    fi
    sleep 2
done
log "Ollama API is ready"

# ---- Pull the model ----
MODEL="${OLLAMA_MODEL:-qwen3-coder:32b}"
header "Pulling Model: $MODEL"

info "This will download the model if not already present..."
info "Model size is typically 18-22GB. Be patient."
echo ""

docker exec openclaw-ollama ollama pull "$MODEL"

log "Model $MODEL is ready"

# Verify model is loaded
MODEL_SIZE=$(docker exec openclaw-ollama ollama list 2>/dev/null | grep "$MODEL" | awk '{print $3, $4}' || echo "unknown")
log "Model size on disk: $MODEL_SIZE"

# ---- Launch Chrome with CDP ----
header "Launching Chrome (CDP mode)"

CHROME_USER_DATA_DIR="${HOME}/.openclaw-chrome-profile"
mkdir -p "$CHROME_USER_DATA_DIR"

info "Starting Chrome with remote debugging on port $CDP_PORT..."
"$CHROME_PATH" \
    --remote-debugging-port="$CDP_PORT" \
    --user-data-dir="$CHROME_USER_DATA_DIR" \
    --no-first-run \
    --no-default-browser-check \
    --disable-background-timer-throttling \
    --disable-backgrounding-occluded-windows \
    --disable-renderer-backgrounding \
    &>/dev/null &

CHROME_PID=$!
sleep 3

# Verify Chrome CDP is running
if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" &>/dev/null; then
    log "Chrome CDP is running on port $CDP_PORT (PID: $CHROME_PID)"
else
    err "Chrome failed to start with CDP. Check if another Chrome instance is running."
    err "Try closing all Chrome windows and run this script again."
    exit 1
fi

# ---- Start OpenClaw ----
header "Starting OpenClaw"

info "Starting OpenClaw container..."
$COMPOSE_CMD up -d openclaw
log "OpenClaw container started"

# Wait for OpenClaw web UI
info "Waiting for OpenClaw web UI..."
RETRIES=0
until curl -sf "http://127.0.0.1:${OPENCLAW_PORT:-8080}" &>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge 30 ]]; then
        warn "OpenClaw web UI not responding yet. It might still be initializing."
        warn "Check logs: docker logs openclaw-agent"
        break
    fi
    sleep 2
done

if [[ $RETRIES -lt 30 ]]; then
    log "OpenClaw web UI is ready"
fi

# ---- Print gateway token ----
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN=$(docker exec openclaw-agent cat /data/.openclaw/.gateway-token 2>/dev/null || echo "")
fi

# ---- Summary ----
header "Setup Complete!"

echo -e "${GREEN}Everything is running. Here's your setup:${NC}"
echo ""
echo -e "  ${BOLD}Ollama${NC}"
echo -e "    API:    http://127.0.0.1:${OLLAMA_PORT:-11434}"
echo -e "    Model:  ${CYAN}$MODEL${NC}"
echo ""
echo -e "  ${BOLD}Chrome${NC}"
echo -e "    CDP:    http://127.0.0.1:$CDP_PORT"
echo -e "    PID:    $CHROME_PID"
echo -e "    Profile: $CHROME_USER_DATA_DIR"
echo ""
echo -e "  ${BOLD}OpenClaw${NC}"
echo -e "    Web UI: ${CYAN}http://127.0.0.1:${OPENCLAW_PORT:-8080}${NC}"
echo -e "    Login:  ${AUTH_USERNAME:-admin} / ${AUTH_PASSWORD:-changeme}"
if [[ -n "$GATEWAY_TOKEN" ]]; then
    echo -e "    Token:  $GATEWAY_TOKEN"
fi
echo ""
echo -e "  ${BOLD}Quick Commands${NC}"
echo -e "    View logs:     docker logs -f openclaw-agent"
echo -e "    Ollama logs:   docker logs -f openclaw-ollama"
echo -e "    Stop all:      ./stop.sh"
echo -e "    Restart:       ./setup.sh"
echo -e "    Change model:  Edit OLLAMA_MODEL in .env, then ./setup.sh"
echo ""
echo -e "${YELLOW}  TIP: Chrome is running with a separate profile.${NC}"
echo -e "${YELLOW}  Log into your accounts (Gmail, etc.) in the Chrome${NC}"
echo -e "${YELLOW}  window — OpenClaw will reuse those sessions.${NC}"
echo ""

# Save PID for stop script
echo "$CHROME_PID" > "$SCRIPT_DIR/.chrome-pid"
