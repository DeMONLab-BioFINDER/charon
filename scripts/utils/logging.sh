#!/bin/bash
# utils/logging.sh

# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# CORE FUNCTION
# ============================================================

_log() {
    local color=$1
    local level=$2
    local msg=$3
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -t 1 ]; then
        echo -e "${BOLD}[${timestamp}]${NC} ${color}${level}:${NC} ${msg}"
    else
        echo "[${timestamp}] ${level}: ${msg}"
    fi
}

# ============================================================
# PUBLIC FUNCTIONS
# ============================================================

log_info()    { _log "$BLUE"   "INFO"    "$1"; }
log_success() { _log "$GREEN"  "SUCCESS" "$1"; }
log_warn()    { _log "$YELLOW" "WARN"    "$1"; }
log_error()   { _log "$RED"    "ERROR"   "$1"; }
log_debug()   { _log "$CYAN"   "DEBUG"   "$1"; }

# ============================================================
# SECTION HEADER
# ============================================================

log_section() {
    local msg=$1
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -t 1 ]; then
        echo -e "\n${BOLD}${BLUE}========================================${NC}"
        echo -e "${BOLD}${BLUE}  ${msg}${NC}"
        echo -e "${BOLD}${BLUE}  ${timestamp}${NC}"
        echo -e "${BOLD}${BLUE}========================================${NC}\n"
    else
        echo ""
        echo "========================================"
        echo "  ${msg}"
        echo "  ${timestamp}"
        echo "========================================"
        echo ""
    fi
}