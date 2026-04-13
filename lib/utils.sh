#!/bin/bash
#
# lib/utils.sh - Utility functions for logging and user interaction
#
# Provides log, warn, error, info, die, vlog functions for consistent
# logging output. Also includes show_header for menu displays.
#
# Dependencies: lib/colors.sh
#

source "${LIB_DIR:-./lib}/colors.sh"

LOG_FILE="${LOG_FILE:-/tmp/macpro-deploy.log}"

log()   { echo -e "${GREEN}[deploy]${NC} $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
die()   { error "$1"; exit 1; }
vlog()  { echo -e "${GREEN}[deploy]${NC} $1" >> "$LOG_FILE"; }

show_header() {
    clear 2>/dev/null || true
    echo "========================================="
    echo " Mac Pro 2013 Ubuntu Server Deployment"
    echo "========================================="
    echo ""
}
