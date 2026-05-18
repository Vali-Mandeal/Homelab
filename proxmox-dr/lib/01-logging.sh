#!/usr/bin/env bash
#
# Logging Functions
# Colored output and section headers
#

# Colors
readonly LOG_RED='\033[0;31m'
readonly LOG_GREEN='\033[0;32m'
readonly LOG_YELLOW='\033[1;33m'
readonly LOG_NC='\033[0m'

log_info() {
    echo -e "${LOG_GREEN}[INFO]${LOG_NC} $1"
}

log_warn() {
    echo -e "${LOG_YELLOW}[WARN]${LOG_NC} $1"
}

log_error() {
    echo -e "${LOG_RED}[ERROR]${LOG_NC} $1"
}

log_section() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
    echo ""
}
