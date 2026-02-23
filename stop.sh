#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Stopping OpenClaw setup...${NC}"

# Stop containers
if docker compose ps -q 2>/dev/null | grep -q .; then
    docker compose down
    echo -e "${GREEN}[✓]${NC} Containers stopped"
else
    echo -e "${GREEN}[✓]${NC} No containers running"
fi

# Kill Chrome CDP
if [[ -f .chrome-pid ]]; then
    CHROME_PID=$(cat .chrome-pid)
    if kill -0 "$CHROME_PID" 2>/dev/null; then
        kill "$CHROME_PID" 2>/dev/null || true
        echo -e "${GREEN}[✓]${NC} Chrome stopped (PID: $CHROME_PID)"
    else
        echo -e "${GREEN}[✓]${NC} Chrome already stopped"
    fi
    rm -f .chrome-pid
else
    echo -e "${GREEN}[✓]${NC} No Chrome PID file found"
fi

echo -e "${GREEN}All stopped.${NC}"
