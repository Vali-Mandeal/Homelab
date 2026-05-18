#!/bin/bash

# Restore script for Nextcloud
# Restores PostgreSQL database and Nextcloud config from the latest backup

set -o pipefail

if [ ! -f "/opt/nextcloud/.env" ]; then
    echo -e "\033[0;31m[RESTORE]\033[0m .env file not found at /opt/nextcloud/.env" >&2
    exit 1
fi

source /opt/nextcloud/.env
export TZ

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

if [ -z "$LOCAL_DB_ROOT" ] || [ -z "$BACKUP_DIR" ]; then
    echo -e "\033[0;31m[RESTORE]\033[0m [$(get_timestamp)] Required environment variables not set." >&2
    exit 1
fi

mkdir -p "$LOGS_DIR"

LOG_FILE="$LOGS_DIR/restore_${TIMESTAMP}.log"

exec > >(tee -a "$LOG_FILE")
exec 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[RESTORE]${NC} [$(get_timestamp)] $1"; }
info() { echo -e "${BLUE}[RESTORE]${NC} [$(get_timestamp)] $1"; }
warn() { echo -e "${YELLOW}[RESTORE]${NC} [$(get_timestamp)] $1"; }
error() { echo -e "${RED}[RESTORE]${NC} [$(get_timestamp)] $1"; }
success() { echo -e "${GREEN}[RESTORE]${NC} [$(get_timestamp)] $1"; }

log "=========================================="
log "Starting Nextcloud restoration"
log "=========================================="
info "Local DB Root: $LOCAL_DB_ROOT"
info "Backup Source: $BACKUP_DIR/backups"
info "Log file: $LOG_FILE"

BACKUP_SRC="$BACKUP_DIR/backups"

# Find latest backup
latest_backup=$(ls -t "$BACKUP_SRC"/nextcloud_backup_*.tar.gz 2>/dev/null | head -1)

if [ -z "$latest_backup" ]; then
    error "No backup found in $BACKUP_SRC"
    exit 1
fi

info "Restoring from: $(basename "$latest_backup")"

# Stop containers
log "Stopping containers..."
cd /opt/nextcloud
if docker compose down 2>&1; then
    info "Containers stopped"
else
    warn "Failed to stop containers"
fi
sleep 5

# Extract backup to temp dir
log "Extracting backup..."
TMP_DIR=$(mktemp -d)
tar -xzf "$latest_backup" -C "$TMP_DIR"

# Restore Nextcloud config
if [ -d "$TMP_DIR/nextcloud-config" ]; then
    log "Restoring Nextcloud config..."
    mkdir -p "$DB_NEXTCLOUD/config"
    cp -a "$TMP_DIR/nextcloud-config/"* "$DB_NEXTCLOUD/config/"
    chown -R 33:33 "$DB_NEXTCLOUD/config"
    success "✓ Nextcloud config restored"
else
    warn "No Nextcloud config found in backup"
fi

# Restore custom_apps if present (app store installs like Talk)
if [ -d "$TMP_DIR/nextcloud-custom_apps" ]; then
    log "Restoring custom_apps..."
    mkdir -p "$DB_NEXTCLOUD/custom_apps"
    cp -a "$TMP_DIR/nextcloud-custom_apps/"* "$DB_NEXTCLOUD/custom_apps/" 2>/dev/null || true
    chown -R 33:33 "$DB_NEXTCLOUD/custom_apps"
    success "✓ Nextcloud custom_apps restored"
else
    warn "No custom_apps found in backup"
fi

# Start only the database container for restore
log "Starting PostgreSQL for database restore..."
docker compose up -d db
sleep 10

# Wait for PostgreSQL to be ready
retries=30
while [ $retries -gt 0 ]; do
    if docker exec nextcloud-db pg_isready -U "$DB_USER" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    retries=$((retries - 1))
done

# Restore PostgreSQL roles (recreates oc_admin user that Nextcloud uses)
if [ -f "$TMP_DIR/nextcloud_roles.sql.gz" ]; then
    log "Restoring PostgreSQL roles..."
    if gunzip < "$TMP_DIR/nextcloud_roles.sql.gz" | docker exec -i nextcloud-db psql -U "$DB_USER" -d postgres >/dev/null 2>&1; then
        success "✓ PostgreSQL roles restored"
    else
        warn "PostgreSQL roles restore had warnings (may be non-fatal)"
    fi
else
    warn "No PostgreSQL roles dump found in backup (old backup format)"
fi

# Restore PostgreSQL database
if [ -f "$TMP_DIR/nextcloud_db.sql.gz" ]; then
    log "Restoring PostgreSQL database..."

    # Drop and recreate database
    docker exec nextcloud-db dropdb -U "$DB_USER" --if-exists nextcloud 2>/dev/null || true
    docker exec nextcloud-db createdb -U "$DB_USER" nextcloud 2>/dev/null || true

    # Restore from dump
    if gunzip < "$TMP_DIR/nextcloud_db.sql.gz" | docker exec -i nextcloud-db psql -U "$DB_USER" -d nextcloud >/dev/null 2>&1; then
        success "✓ PostgreSQL database restored"
    else
        error "Failed to restore PostgreSQL database"
    fi
else
    warn "No PostgreSQL dump found in backup"
fi

# Cleanup temp dir
rm -rf "$TMP_DIR"

# Start all containers
log "Starting all containers..."
docker compose up -d

# Wait for Nextcloud
log "Waiting for Nextcloud to start..."
sleep 30

# Run maintenance tasks
log "Running maintenance tasks..."
docker exec -u www-data nextcloud php occ maintenance:mode --off 2>/dev/null || true
docker exec -u www-data nextcloud php occ maintenance:repair 2>/dev/null || true
docker exec -u www-data nextcloud php occ db:add-missing-indices 2>/dev/null || true
docker exec -u www-data nextcloud php occ db:add-missing-columns 2>/dev/null || true
docker exec -u www-data nextcloud php occ db:add-missing-primary-keys 2>/dev/null || true

log "=========================================="
success "Restoration complete!"
log "  Logs stored in: $LOG_FILE"
log "=========================================="
