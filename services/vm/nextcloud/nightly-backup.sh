#!/bin/bash

# Nightly backup script for Nextcloud
# Backs up PostgreSQL database and Nextcloud config to SMB storage
# Uses maintenance mode instead of stopping containers

set -o pipefail

if [ ! -f "/opt/nextcloud/.env" ]; then
    echo "[ERROR] .env file not found at /opt/nextcloud/.env" >&2
    exit 1
fi

source /opt/nextcloud/.env
export TZ

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

if [ -z "$LOCAL_DB_ROOT" ] || [ -z "$BACKUP_DIR" ]; then
    echo "[$(get_timestamp)] [ERROR] Required environment variables not set." >&2
    exit 1
fi

mkdir -p "$LOGS_DIR"

LOG_FILE="$LOGS_DIR/backup_${TIMESTAMP}.log"

exec > >(tee -a "$LOG_FILE")
exec 2>&1

log() { echo "[$(get_timestamp)] [INFO] $1"; }
info() { echo "[$(get_timestamp)] [INFO] $1"; }
warn() { echo "[$(get_timestamp)] [WARN] $1"; }
error() { echo "[$(get_timestamp)] [ERROR] $1"; }
success() { echo "[$(get_timestamp)] [SUCCESS] $1"; }

log "=========================================="
log "Starting nightly Nextcloud backup"
log "=========================================="
info "Local DB Root: $LOCAL_DB_ROOT"
info "Backup Destination: $BACKUP_DIR/backups"
info "Log file: $LOG_FILE"

BACKUP_DEST="$BACKUP_DIR/backups"
mkdir -p "$BACKUP_DEST"

# Create temp directory for assembling backup
TMP_DIR=$(mktemp -d)
BACKUP_FAILED=false

# Enable maintenance mode
log "Enabling maintenance mode..."
if docker exec -u www-data nextcloud php occ maintenance:mode --on 2>&1; then
    info "Maintenance mode enabled"
else
    warn "Failed to enable maintenance mode, continuing anyway"
fi

# Dump PostgreSQL roles (cluster-level - not included in pg_dump)
# Nextcloud's occ maintenance:install creates an app-specific user (oc_<admin>)
# that must be restored alongside the database for authentication to work.
log "Dumping PostgreSQL roles..."
if docker exec nextcloud-db pg_dumpall -U "$DB_USER" --roles-only | gzip > "$TMP_DIR/nextcloud_roles.sql.gz" 2>/dev/null; then
    success "PostgreSQL roles dumped"
else
    warn "PostgreSQL roles dump failed (non-fatal - roles can be recreated)"
fi

# Dump PostgreSQL database
log "Dumping PostgreSQL database..."
if docker exec nextcloud-db pg_dump -U "$DB_USER" nextcloud | gzip > "$TMP_DIR/nextcloud_db.sql.gz" 2>/dev/null; then
    local_size=$(du -h "$TMP_DIR/nextcloud_db.sql.gz" | cut -f1)
    success "PostgreSQL dump complete ($local_size)"
else
    error "PostgreSQL dump failed"
    BACKUP_FAILED=true
fi

# Backup Nextcloud config
log "Backing up Nextcloud config..."
if [ -d "$DB_NEXTCLOUD/config" ]; then
    cp -a "$DB_NEXTCLOUD/config" "$TMP_DIR/nextcloud-config"
    success "Nextcloud config backed up"
else
    warn "Nextcloud config directory not found at $DB_NEXTCLOUD/config"
fi

# Backup Nextcloud custom_apps (app store installs like Talk)
log "Backing up custom_apps..."
if [ -d "$DB_NEXTCLOUD/custom_apps" ]; then
    cp -a "$DB_NEXTCLOUD/custom_apps" "$TMP_DIR/nextcloud-custom_apps"
    success "Nextcloud custom_apps backed up"
else
    info "No custom_apps directory found (no app store installs)"
fi

# Disable maintenance mode
log "Disabling maintenance mode..."
if docker exec -u www-data nextcloud php occ maintenance:mode --off 2>&1; then
    info "Maintenance mode disabled"
else
    error "Failed to disable maintenance mode! Run manually: docker exec -u www-data nextcloud php occ maintenance:mode --off"
fi

# Create final backup archive
log "Creating backup archive..."
BACKUP_FILE="$BACKUP_DEST/nextcloud_backup_${TIMESTAMP}.tar.gz"

if tar -czf "$BACKUP_FILE" -C "$TMP_DIR" . 2>/dev/null; then
    backup_size=$(du -h "$BACKUP_FILE" | cut -f1)
    success "Backup archive created ($backup_size): $(basename "$BACKUP_FILE")"
else
    error "Failed to create backup archive"
    BACKUP_FAILED=true
fi

# Cleanup temp dir
rm -rf "$TMP_DIR"

# Retention: keep last 7 backups
log "Cleaning up old backups (keeping last 7)..."
old_backups=$(ls -t "$BACKUP_DEST"/nextcloud_backup_*.tar.gz 2>/dev/null | tail -n +8 || true)
if [ -n "$old_backups" ]; then
    echo "$old_backups" | xargs rm -f
    info "✓ Old backups cleaned up"
else
    info "✓ No old backups to clean up"
fi

# Summary
log "=========================================="
if [ "$BACKUP_FAILED" = true ]; then
    error "Backup completed with errors. Check logs above."
    log "=========================================="
    exit 1
else
    success "Backup completed successfully!"
    log "=========================================="
    exit 0
fi
