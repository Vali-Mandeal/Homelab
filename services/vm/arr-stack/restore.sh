#!/bin/bash

# Configuration and database restoration script for ARR stack
# This restores from the latest tar.gz backups

set -o pipefail

# Check if we're in the right directory
if [ ! -f "/opt/arr/.env" ]; then
    echo -e "\033[0;31m[RESTORE]\033[0m .env file not found at /opt/arr/.env" >&2
    exit 1
fi

# Source environment variables (including TZ)
source /opt/arr/.env

# Export TZ so date commands use it
export TZ

# Timestamp for filenames and logging (now using correct timezone)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Function to get current timestamp (called each time for accurate logging)
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Verify required variables
if [ -z "$LOCAL_DB_ROOT" ] || [ -z "$ARR_ROOT" ]; then
    echo -e "\033[0;31m[RESTORE]\033[0m [$(get_timestamp)] Required environment variables not set." >&2
    exit 1
fi

# Create logs directory
mkdir -p "$LOGS_DIR"

# Create timestamped log file name
LOG_FILE="$LOGS_DIR/restore_${TIMESTAMP}.log"

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions with dynamic timestamps
log() { echo -e "${GREEN}[RESTORE]${NC} [$(get_timestamp)] $1"; }
info() { echo -e "${BLUE}[RESTORE]${NC} [$(get_timestamp)] $1"; }
warn() { echo -e "${YELLOW}[RESTORE]${NC} [$(get_timestamp)] $1"; }
error() { echo -e "${RED}[RESTORE]${NC} [$(get_timestamp)] $1"; }
success() { echo -e "${GREEN}[RESTORE]${NC} [$(get_timestamp)] $1"; }

log "=========================================="
log "Starting configuration and database restoration"
log "=========================================="
info "Local DB Root: $LOCAL_DB_ROOT"
info "Backup Source: $ARR_ROOT"
info "Log file: $LOG_FILE"

# Stop containers for clean restore
log "Stopping containers for clean restore..."
cd /opt/arr
if docker compose stop 2>&1; then
    info "Containers stopped successfully"
else
    warn "No containers running or failed to stop"
fi
info "Waiting for containers to fully stop..."
sleep 5

# Create local database directories
info "Creating local database directories..."
mkdir -p "$DB_RADARR" "$DB_SONARR" "$DB_PROWLARR" "$DB_JELLYSEERR" "$DB_QBITTORRENT"
chown -R $PUID:$PGID "$LOCAL_DB_ROOT"
chmod -R 755 "$LOCAL_DB_ROOT"

# Function to restore from tar.gz backup
restore_from_backup() {
    local app_name="$1"
    local backup_dir="$2"
    local local_db_dir="$3"

    info "Checking for $app_name backups..."

    if [ ! -d "$backup_dir" ]; then
        warn "No backup directory for $app_name (fresh install)"
        return 0
    fi

    # Find the most recent backup
    local latest_backup=$(ls -t "$backup_dir"/${app_name}_backup_*.tar.gz 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        info "No backup found for $app_name (fresh install)"
        return 0
    fi

    info "Restoring $app_name from: $(basename "$latest_backup")"

    # Extract backup to parent directory (tar contains the app directory itself)
    local parent_dir=$(dirname "$local_db_dir")
    if tar -xzf "$latest_backup" -C "$parent_dir" 2>/dev/null; then
        chown -R $PUID:$PGID "$local_db_dir"
        success "✓ Restored $app_name successfully"
        return 0
    else
        error "Failed to restore $app_name"
        return 1
    fi
}

# Restore configurations for each application
TOTAL_SUCCESS=0
TOTAL_FAILED=0

for app in radarr sonarr prowlarr jellyseerr qbittorrent; do
    app_upper=$(echo "$app" | tr '[:lower:]' '[:upper:]')
    backup_var="BACKUP_${app_upper}"
    db_var="DB_${app_upper}"

    backup_dir="${!backup_var}"
    db_dir="${!db_var}"

    if restore_from_backup "$app" "$backup_dir" "$db_dir"; then
        ((TOTAL_SUCCESS++))
    else
        ((TOTAL_FAILED++))
    fi
done

log "=========================================="
log "Restore Summary:"
info "  Successful: $TOTAL_SUCCESS"
if [ $TOTAL_FAILED -gt 0 ]; then
    error "  Failed: $TOTAL_FAILED"
else
    info "  Failed: $TOTAL_FAILED"
fi
log "  Logs stored in: $LOG_FILE"
log "=========================================="

# Restart containers
log "Starting containers..."
cd /opt/arr
if docker compose start 2>&1; then
    success "Containers started successfully"
else
    error "Failed to start containers!"
fi

if [ $TOTAL_FAILED -eq 0 ]; then
    success "All configurations restored successfully!"
    exit 0
else
    error "Some restores failed. Check logs above for details."
    exit 1
fi
