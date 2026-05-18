#!/bin/bash

# Jellyfin Nightly Backup Script
# Stops Jellyfin, backs up database, starts Jellyfin
# Similar to ARR stack backup approach

# Set timezone to Europe/Bucharest (EEST)
export TZ="Europe/Bucharest"

# Configuration
JELLYFIN_DATA="/var/lib/jellyfin"

# BACKUP_ROOT comes from /etc/jellyfin-runtime.env (written by deploy.sh)
if [[ -f /etc/jellyfin-runtime.env ]]; then
    set -a; source /etc/jellyfin-runtime.env; set +a
fi
: "${BACKUP_ROOT:?BACKUP_ROOT not set - re-run jellyfin deploy}"

BACKUP_DIR="$BACKUP_ROOT/backups"
LOG_DIR="$BACKUP_ROOT/logs"
RETENTION_DAYS=7

# Function to get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Create timestamped log file
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/backup_$TIMESTAMP.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Redirect all output to log file AND console
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================================"
echo "Jellyfin Backup Started: $(get_timestamp)"
echo "================================================================"

# Stop Jellyfin to prevent database corruption
echo "[$(get_timestamp)] Stopping Jellyfin..."
systemctl stop jellyfin
# Wait for clean shutdown
sleep 5

# Verify Jellyfin is stopped
if systemctl is-active --quiet jellyfin; then
    echo "[$(get_timestamp)] ERROR: Jellyfin failed to stop!"
    exit 1
fi

echo "[$(get_timestamp)] ✓ Jellyfin stopped"

# Backup Jellyfin data
echo "[$(get_timestamp)] Backing up Jellyfin data..."

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Create backup with timestamp
# Includes /var/lib/jellyfin (database, metadata, plugins)
# and /etc/jellyfin (system.xml with wizard flag, network config, etc.)
BACKUP_FILE="$BACKUP_DIR/jellyfin_backup_$TIMESTAMP.tar.gz"

if tar -czf "$BACKUP_FILE" -C / var/lib/jellyfin etc/jellyfin 2>/dev/null; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "[$(get_timestamp)] ✓ Backup created: $BACKUP_FILE ($BACKUP_SIZE)"
else
    echo "[$(get_timestamp)] ERROR: Backup failed!"
    systemctl start jellyfin
    exit 1
fi

# Start Jellyfin
echo "[$(get_timestamp)] Starting Jellyfin..."
systemctl start jellyfin

# Wait and verify startup
sleep 3

if systemctl is-active --quiet jellyfin; then
    echo "[$(get_timestamp)] ✓ Jellyfin started successfully"
else
    echo "[$(get_timestamp)] WARNING: Jellyfin may not have started properly"
    systemctl status jellyfin --no-pager
fi

# Cleanup old backups (keep last 7 days)
echo "[$(get_timestamp)] Cleaning up old backups (keeping last $RETENTION_DAYS days)..."

OLD_BACKUPS=$(find "$BACKUP_DIR" -name "jellyfin_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS 2>/dev/null)

if [ -n "$OLD_BACKUPS" ]; then
    echo "$OLD_BACKUPS" | while read -r old_backup; do
        rm -f "$old_backup"
        echo "[$(get_timestamp)] Deleted: $(basename "$old_backup")"
    done
else
    echo "[$(get_timestamp)] No old backups to clean"
fi

# Show current backups
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/jellyfin_backup_*.tar.gz 2>/dev/null | wc -l)
echo "[$(get_timestamp)] Total backups: $BACKUP_COUNT"

echo "================================================================"
echo "Jellyfin Backup Completed: $(get_timestamp)"
echo "================================================================"
