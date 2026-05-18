#!/bin/bash

# Jellyfin Manual Restore Script
# Restores Jellyfin database from latest backup

# Set timezone to Europe/Bucharest (EEST)
export TZ="Europe/Bucharest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() { echo -e "${GREEN}[RESTORE]${NC} $1"; }
warn() { echo -e "${YELLOW}[RESTORE]${NC} $1"; }
error() { echo -e "${RED}[RESTORE]${NC} $1"; exit 1; }

# Configuration
JELLYFIN_DATA="/var/lib/jellyfin"

# BACKUP_ROOT comes from /etc/jellyfin-runtime.env (written by deploy.sh)
if [[ -f /etc/jellyfin-runtime.env ]]; then
    set -a; source /etc/jellyfin-runtime.env; set +a
fi
: "${BACKUP_ROOT:?BACKUP_ROOT not set - re-run jellyfin deploy}"

BACKUP_DIR="$BACKUP_ROOT/backups"
LOG_DIR="$BACKUP_ROOT/logs"

# Create timestamped log file
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/restore_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================================"
echo "Jellyfin Restore Started: $(get_timestamp)"
echo "================================================================"

# Find latest backup
log "Looking for latest backup..."
LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/jellyfin_backup_*.tar.gz 2>/dev/null | head -1)

if [ -z "$LATEST_BACKUP" ] || [ ! -f "$LATEST_BACKUP" ]; then
    error "No backup found in $BACKUP_DIR"
fi

log "Found backup: $(basename "$LATEST_BACKUP")"
BACKUP_SIZE=$(du -h "$LATEST_BACKUP" | cut -f1)
BACKUP_DATE=$(stat -c %y "$LATEST_BACKUP" 2>/dev/null || stat -f "%Sm" "$LATEST_BACKUP")
log "Size: $BACKUP_SIZE"
log "Date: $BACKUP_DATE"

# Confirm restore
warn "This will REPLACE current Jellyfin data with backup!"
warn "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
sleep 5

# Stop Jellyfin
log "Stopping Jellyfin..."
systemctl stop jellyfin
sleep 3

if systemctl is-active --quiet jellyfin; then
    error "Failed to stop Jellyfin!"
fi

log "✓ Jellyfin stopped"

# Backup current data (just in case)
if [ -d "$JELLYFIN_DATA" ] && [ -n "$(ls -A "$JELLYFIN_DATA" 2>/dev/null)" ]; then
    log "Creating safety backup of current data..."
    SAFETY_BACKUP="$BACKUP_DIR/jellyfin_pre_restore_$TIMESTAMP.tar.gz"
    tar -czf "$SAFETY_BACKUP" -C /var/lib jellyfin 2>/dev/null || true
    log "Safety backup saved: $(basename "$SAFETY_BACKUP")"
fi

# Remove old data
log "Removing current Jellyfin data..."
rm -rf "$JELLYFIN_DATA"/*

# Restore from backup
# Backups may contain both var/lib/jellyfin and etc/jellyfin
log "Restoring from backup..."
if tar -xzf "$LATEST_BACKUP" -C / 2>/dev/null; then
    log "✓ Backup extracted (new format with config)"
else
    # Fallback: try old backup format (relative to /var/lib)
    if tar -xzf "$LATEST_BACKUP" -C /var/lib 2>/dev/null; then
        log "✓ Backup extracted (legacy format)"
    else
        error "Failed to extract backup!"
    fi
fi

# Fix permissions
log "Fixing permissions..."
chown -R jellyfin:jellyfin "$JELLYFIN_DATA"
chown -R jellyfin:jellyfin /etc/jellyfin 2>/dev/null || true
log "✓ Permissions fixed"

# Start Jellyfin
log "Starting Jellyfin..."
systemctl start jellyfin
sleep 5

if systemctl is-active --quiet jellyfin; then
    log "✓ Jellyfin started successfully"
else
    warn "Jellyfin may not have started properly"
    systemctl status jellyfin --no-pager
fi

echo "================================================================"
echo "Jellyfin Restore Completed: $(get_timestamp)"
echo "================================================================"
echo ""
log "Jellyfin should now be running with restored data"
log "Check status: systemctl status jellyfin"
log "View logs: journalctl -u jellyfin -f"
