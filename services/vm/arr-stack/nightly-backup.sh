#!/bin/bash

# Nightly database backup script for ARR stack
# This runs via cron to backup local databases to SMB storage

set -o pipefail

# Check if we're in the right directory
if [ ! -f "/opt/arr/.env" ]; then
    echo "[ERROR] .env file not found at /opt/arr/.env" >&2
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
    echo "[$(get_timestamp)] [ERROR] Required environment variables not set. Check your .env file." >&2
    exit 1
fi

# Create logs directory
mkdir -p "$LOGS_DIR"

# Create timestamped log file name
LOG_FILE="$LOGS_DIR/backup_${TIMESTAMP}.log"

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

# Logging functions with dynamic timestamps
log() { echo "[$(get_timestamp)] [INFO] $1"; }
info() { echo "[$(get_timestamp)] [INFO] $1"; }
warn() { echo "[$(get_timestamp)] [WARN] $1"; }
error() { echo "[$(get_timestamp)] [ERROR] $1"; }
success() { echo "[$(get_timestamp)] [SUCCESS] $1"; }

log "=========================================="
log "Starting nightly backup of ARR stack"
log "=========================================="
info "Local DB Root: $LOCAL_DB_ROOT"
info "Backup Destination: $ARR_ROOT"
info "Log file: $LOG_FILE"

# Stop containers for clean backup
log "Stopping containers for clean backup..."
cd /opt/arr
if docker compose stop 2>&1; then
    info "Containers stopped successfully"
else
    warn "Failed to stop containers, continuing anyway"
fi
info "Waiting for containers to fully stop..."
sleep 5

# Create backup directories if they don't exist
mkdir -p "$BACKUP_RADARR" "$BACKUP_SONARR" "$BACKUP_PROWLARR" "$BACKUP_JELLYSEERR" "$BACKUP_QBITTORRENT"

# Function to backup an entire config directory as tar.gz
backup_config() {
    local app_name="$1"
    local local_db_dir="$2"
    local backup_dir="$3"
    local backup_retention=${4:-7}  # Keep 7 backups by default

    info "Backing up $app_name configuration..."

    if [ ! -d "$local_db_dir" ]; then
        warn "$app_name configuration directory not found: $local_db_dir"
        return 1
    fi

    local backup_file="$backup_dir/${app_name}_backup_${TIMESTAMP}.tar.gz"

    # Create tar.gz archive of the entire config directory
    # Exclude temporary SQLite files (WAL and SHM will be checkpointed)
    if tar -czf "$backup_file" \
        -C "$(dirname "$local_db_dir")" \
        --exclude="*.db-wal" \
        --exclude="*.db-shm" \
        --exclude="*.sqlite3-wal" \
        --exclude="*.sqlite3-shm" \
        --exclude="logs/*" \
        --exclude="Backups/*" \
        "$(basename "$local_db_dir")" 2>/dev/null; then

        # Verify the backup was created
        if [ -f "$backup_file" ]; then
            local size=$(du -h "$backup_file" | cut -f1)
            success "$app_name backed up successfully ($size) -> $(basename "$backup_file")"

            # Keep only the last N backups for this app
            info "Cleaning up old $app_name backups (keeping last $backup_retention)..."
            local old_backups=$(ls -t "$backup_dir"/${app_name}_backup_*.tar.gz 2>/dev/null | tail -n +$((backup_retention + 1)) || true)
            if [ -n "$old_backups" ]; then
                echo "$old_backups" | xargs rm -f
                info "✓ Old $app_name backups cleaned up"
            else
                info "✓ No old backups to clean up"
            fi

            return 0
        else
            error "Backup file was not created for $app_name"
            return 1
        fi
    else
        error "Failed to create backup for $app_name"
        return 1
    fi
}

# Backup complete config directories for each application
TOTAL_SUCCESS=0
TOTAL_FAILED=0

for app in radarr sonarr prowlarr jellyseerr qbittorrent; do
    app_upper=$(echo "$app" | tr '[:lower:]' '[:upper:]')
    source_var="DB_${app_upper}"
    backup_var="BACKUP_${app_upper}"

    # Check if variables are set
    if [ -z "${!source_var:-}" ]; then
        warn "$app: Source variable $source_var is not set, skipping"
        ((TOTAL_FAILED++))
        continue
    fi

    if [ -z "${!backup_var:-}" ]; then
        warn "$app: Backup variable $backup_var is not set, skipping"
        ((TOTAL_FAILED++))
        continue
    fi

    source_dir="${!source_var}"
    backup_dir="${!backup_var}"

    # Run backup and capture any errors
    if backup_config "$app" "$source_dir" "$backup_dir" 2>&1; then
        ((TOTAL_SUCCESS++))
    else
        ((TOTAL_FAILED++))
    fi
done

# Summary
log "=========================================="
log "Backup Summary:"
info "  Successful: $TOTAL_SUCCESS"
if [ $TOTAL_FAILED -gt 0 ]; then
    error "  Failed: $TOTAL_FAILED"
else
    info "  Failed: $TOTAL_FAILED"
fi
log "  Logs stored in: $LOG_FILE"
log "=========================================="

# Restart containers
log "Restarting containers..."
cd /opt/arr
if docker compose start 2>&1; then
    success "Containers restarted successfully"
else
    error "Failed to restart containers!"
fi

if [ $TOTAL_FAILED -eq 0 ]; then
    success "All backups completed successfully!"
    exit 0
else
    error "Some backups failed. Check logs above for details."
    exit 1
fi
