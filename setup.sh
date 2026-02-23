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

# ---- Start OpenClaw + Browser ----
header "Starting OpenClaw + Browser"

info "Starting browser sidecar and OpenClaw..."
$COMPOSE_CMD up -d
log "All containers started"

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

# ---- Summary ----
header "Setup Complete!"

echo -e "${GREEN}Everything is running. Here's your setup:${NC}"
echo ""
echo -e "  ${BOLD}Ollama${NC}"
echo -e "    API:    http://127.0.0.1:${OLLAMA_PORT:-11434}"
echo -e "    Model:  ${CYAN}$MODEL${NC}"
echo ""
echo -e "  ${BOLD}Browser${NC}"
echo -e "    Managed by Docker sidecar (openclaw-browser)"
echo -e "    Access via OpenClaw Web UI: ${CYAN}http://127.0.0.1:${OPENCLAW_PORT:-8080}/browser/${NC}"
echo ""
echo -e "  ${BOLD}OpenClaw${NC}"
echo -e "    Web UI: ${CYAN}http://127.0.0.1:${OPENCLAW_PORT:-8080}${NC}"
echo -e "    Login:  ${AUTH_USERNAME:-admin} / ${AUTH_PASSWORD:-changeme}"
echo ""
echo -e "  ${BOLD}Quick Commands${NC}"
echo -e "    View logs:     docker logs -f openclaw-agent"
echo -e "    Ollama logs:   docker logs -f openclaw-ollama"
echo -e "    Browser logs:  docker logs -f openclaw-browser"
echo -e "    Stop all:      ./stop.sh"
echo -e "    Restart:       ./setup.sh"
echo -e "    Change model:  Edit OLLAMA_MODEL in .env, then ./setup.sh"
echo ""
echo -e "${YELLOW}  TIP: Go to http://127.0.0.1:${OPENCLAW_PORT:-8080}/browser/${NC}"
echo -e "${YELLOW}  to see the browser. Log into your accounts (Gmail, etc.)${NC}"
echo -e "${YELLOW}  there — OpenClaw will reuse those sessions.${NC}"
echo ""
