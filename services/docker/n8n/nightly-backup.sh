#!/bin/bash

# Nightly backup script for n8n
# Stops containers, backs up n8n + Postgres data, restarts
# Follows the same pattern as monitoring/ARR stack backups

set -o pipefail

export TZ="Europe/Bucharest"

COMPOSE_DIR="/opt/n8n"

# BACKUP_DIR and LOG_DIR come from /opt/n8n/.env (written by deploy.sh)
if [[ -f /opt/n8n/.env ]]; then
    set -a; source /opt/n8n/.env; set +a
fi
: "${BACKUP_DIR:?BACKUP_DIR not set - re-run n8n deploy}"
: "${LOG_DIR:?LOG_DIR not set - re-run n8n deploy}"

RETENTION_COUNT=7

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

LOG_FILE="$LOG_DIR/backup_${TIMESTAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo "[$(get_timestamp)] [INFO] $1"; }
error()   { echo "[$(get_timestamp)] [ERROR] $1"; }
success() { echo "[$(get_timestamp)] [SUCCESS] $1"; }

log "=========================================="
log "Starting nightly backup of n8n"
log "=========================================="
log "Backup Destination: $BACKUP_DIR"
log "Log file: $LOG_FILE"

# ==============================================================================
# Stop containers for clean backup
# ==============================================================================

log "Stopping containers for clean backup..."
cd "$COMPOSE_DIR"
if docker compose stop 2>&1; then
    log "Containers stopped successfully"
else
    error "Failed to stop containers, continuing anyway"
fi
sleep 5

# ==============================================================================
# Backup Docker volumes
# ==============================================================================

BACKUP_FILE="$BACKUP_DIR/n8n_backup_${TIMESTAMP}.tar.gz"

log "Backing up Docker volumes..."

N8N_VOL=$(docker volume inspect n8n_n8n-data    -f '{{.Mountpoint}}' 2>/dev/null || echo "")
DB_VOL=$(docker  volume inspect n8n_n8n-db-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")

TAR_ARGS=()

if [[ -n "$N8N_VOL" && -d "$N8N_VOL" ]]; then
    TAR_ARGS+=(-C "$(dirname "$N8N_VOL")" "$(basename "$N8N_VOL")")
    log "  Including n8n data: $N8N_VOL"
fi

if [[ -n "$DB_VOL" && -d "$DB_VOL" ]]; then
    TAR_ARGS+=(-C "$(dirname "$DB_VOL")" "$(basename "$DB_VOL")")
    log "  Including Postgres data: $DB_VOL"
fi

if [[ ${#TAR_ARGS[@]} -eq 0 ]]; then
    error "No volumes found to backup!"
    docker compose start 2>&1
    exit 1
fi

if tar -czf "$BACKUP_FILE" "${TAR_ARGS[@]}" 2>/dev/null; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    success "Backup created: $(basename "$BACKUP_FILE") ($BACKUP_SIZE)"
else
    error "Backup failed!"
    docker compose start 2>&1
    exit 1
fi

# ==============================================================================
# Restart containers
# ==============================================================================

log "Restarting containers..."
cd "$COMPOSE_DIR"
if docker compose start 2>&1; then
    success "Containers restarted successfully"
else
    error "Failed to restart containers!"
fi

# ==============================================================================
# Cleanup old backups
# ==============================================================================

log "Cleaning up old backups (keeping last $RETENTION_COUNT)..."

OLD_BACKUPS=$(ls -t "$BACKUP_DIR"/n8n_backup_*.tar.gz 2>/dev/null | tail -n +$((RETENTION_COUNT + 1)) || true)
if [[ -n "$OLD_BACKUPS" ]]; then
    echo "$OLD_BACKUPS" | xargs rm -f
    log "Old backups cleaned up"
else
    log "No old backups to clean up"
fi

BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/n8n_backup_*.tar.gz 2>/dev/null | wc -l)
log "Total backups: $BACKUP_COUNT"

log "=========================================="
log "n8n Backup Completed: $(get_timestamp)"
log "=========================================="
