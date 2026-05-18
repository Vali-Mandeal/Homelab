#!/bin/bash

# Restore script for n8n
# Restores n8n + Postgres data from a backup

set -euo pipefail

export TZ="Europe/Bucharest"

COMPOSE_DIR="/opt/n8n"

if [[ -f /opt/n8n/.env ]]; then
    set -a; source /opt/n8n/.env; set +a
fi
: "${BACKUP_DIR:?BACKUP_DIR not set - re-run n8n deploy}"

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log()     { echo "[$(get_timestamp)] [INFO] $1"; }
error()   { echo "[$(get_timestamp)] [ERROR] $1"; }
success() { echo "[$(get_timestamp)] [SUCCESS] $1"; }

# ==============================================================================
# Select backup
# ==============================================================================

echo ""
echo "Available backups:"
echo ""

BACKUPS=($(ls -t "$BACKUP_DIR"/n8n_backup_*.tar.gz 2>/dev/null))

if [[ ${#BACKUPS[@]} -eq 0 ]]; then
    error "No backups found in $BACKUP_DIR"
    exit 1
fi

for i in "${!BACKUPS[@]}"; do
    local_file="${BACKUPS[$i]}"
    size=$(du -h "$local_file" | cut -f1)
    name=$(basename "$local_file")
    echo "  $((i + 1))) $name ($size)"
done

echo ""
read -r -p "Select backup to restore (1-${#BACKUPS[@]}): " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#BACKUPS[@]} ]]; then
    error "Invalid selection"
    exit 1
fi

SELECTED="${BACKUPS[$((choice - 1))]}"
log "Selected: $(basename "$SELECTED")"

# ==============================================================================
# Confirm
# ==============================================================================

echo ""
echo "WARNING: This will stop n8n and replace all data."
read -r -p "Continue? (y/N): " confirm

if [[ "${confirm,,}" != "y" ]]; then
    log "Restore cancelled"
    exit 0
fi

# ==============================================================================
# Stop containers
# ==============================================================================

log "Stopping containers..."
cd "$COMPOSE_DIR"
docker compose down

# ==============================================================================
# Wipe and restore volumes
# ==============================================================================

log "Removing existing volumes..."
docker volume rm n8n_n8n-data n8n_n8n-db-data 2>/dev/null || true

log "Recreating volumes..."
docker volume create n8n_n8n-data
docker volume create n8n_n8n-db-data

log "Extracting backup..."
N8N_MOUNT=$(docker volume inspect n8n_n8n-data    -f '{{.Mountpoint}}')
DB_MOUNT=$(docker  volume inspect n8n_n8n-db-data -f '{{.Mountpoint}}')

tar -xzf "$SELECTED" -C "$(dirname "$N8N_MOUNT")" 2>/dev/null || true
tar -xzf "$SELECTED" -C "$(dirname "$DB_MOUNT")"  2>/dev/null || true

success "Data restored from $(basename "$SELECTED")"

# ==============================================================================
# Restart
# ==============================================================================

log "Starting containers..."
cd "$COMPOSE_DIR"
docker compose up -d

success "n8n restore complete"
