#!/bin/bash
# ==============================================================================
# Nextcloud VM - Nightly Security Updates
# ==============================================================================
# Applies OS security patches to the Nextcloud VM host.
# Scheduled via cron (see bootstrap.sh). Logs to the backup log directory.
# ==============================================================================

set -euo pipefail

source /opt/nextcloud/.env

# LOGS_DIR is set in /opt/nextcloud/.env (deploy-time). Fall back to a local
# path only if the env was somehow not sourced.
LOG_DIR="${LOGS_DIR:-/var/log/nextcloud-security-updates}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/security_updates_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "Starting security updates..."

DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1
UPGRADE_OUTPUT=$(DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>&1) || true
echo "$UPGRADE_OUTPUT" >> "$LOG_FILE"

# Count upgraded packages
UPGRADED=$(echo "$UPGRADE_OUTPUT" | grep -c "^Setting up" || true)

if [ "$UPGRADED" -gt 0 ]; then
    log "Applied ${UPGRADED} package update(s)"

else
    log "No updates available"
fi

# Clean up old logs (keep last 30 days)
find "$LOG_DIR" -name "security_updates_*.log" -mtime +30 -delete 2>/dev/null || true

# Reboot if required (kernel updates, libc, etc.)
if [ -f /var/run/reboot-required ]; then
    log "Reboot required - stopping Docker containers gracefully..."
    cd /opt/nextcloud && docker compose stop >> "$LOG_FILE" 2>&1 || true
    log "Containers stopped. Rebooting now..."
    reboot
else
    log "Security updates complete - no reboot needed"
fi
