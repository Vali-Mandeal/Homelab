#!/bin/bash

# Nightly backup script for Monitoring Stack
# Stops containers, backs up Grafana + Prometheus + Loki data, restarts
# Follows the same pattern as ARR stack and Jellyfin backups

set -o pipefail

export TZ="Europe/Bucharest"

# Configuration
COMPOSE_DIR="/opt/monitoring"

# BACKUP_DIR and LOG_DIR come from /opt/monitoring/.env (written by deploy.sh)
if [[ -f /opt/monitoring/.env ]]; then
    set -a; source /opt/monitoring/.env; set +a
fi
: "${BACKUP_DIR:?BACKUP_DIR not set - re-run monitoring deploy}"
: "${LOG_DIR:?LOG_DIR not set - re-run monitoring deploy}"

RETENTION_COUNT=7

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Ensure directories exist
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# Create timestamped log file
LOG_FILE="$LOG_DIR/backup_${TIMESTAMP}.log"

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo "[$(get_timestamp)] [INFO] $1"; }
error()   { echo "[$(get_timestamp)] [ERROR] $1"; }
success() { echo "[$(get_timestamp)] [SUCCESS] $1"; }

log "=========================================="
log "Starting nightly backup of Monitoring Stack"
log "=========================================="
log "Backup Destination: $BACKUP_DIR"
log "Log file: $LOG_FILE"

# ==============================================================================
# Export Grafana dashboards (while still running)
# ==============================================================================

log "Exporting Grafana dashboards..."
DASHBOARDS_DIR="/tmp/grafana-dashboards-${TIMESTAMP}"
mkdir -p "$DASHBOARDS_DIR"

# Get all dashboard UIDs
DASHBOARD_UIDS=$(curl -sf http://localhost:3001/api/search?type=dash-db \
    -H "Authorization: Basic $(echo -n 'admin:changeme' | base64)" \
    2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for d in data:
        print(d.get('uid', ''))
except:
    pass
" 2>/dev/null || true)

DASH_COUNT=0
for uid in $DASHBOARD_UIDS; do
    [[ -z "$uid" ]] && continue
    curl -sf "http://localhost:3001/api/dashboards/uid/${uid}" \
        -H "Authorization: Basic $(echo -n 'admin:changeme' | base64)" \
        > "${DASHBOARDS_DIR}/${uid}.json" 2>/dev/null && ((DASH_COUNT++)) || true
done

if [[ $DASH_COUNT -gt 0 ]]; then
    log "Exported ${DASH_COUNT} Grafana dashboard(s)"
else
    log "No custom dashboards to export (or Grafana not reachable)"
fi

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

BACKUP_FILE="$BACKUP_DIR/monitoring_backup_${TIMESTAMP}.tar.gz"

log "Backing up Docker volumes and dashboards..."

# Find actual volume paths
GRAFANA_VOL=$(docker volume inspect monitoring_grafana-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")
PROMETHEUS_VOL=$(docker volume inspect monitoring_prometheus-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")
LOKI_VOL=$(docker volume inspect monitoring_loki-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")

TAR_ARGS=()

if [[ -n "$GRAFANA_VOL" && -d "$GRAFANA_VOL" ]]; then
    TAR_ARGS+=(-C "$(dirname "$GRAFANA_VOL")" "$(basename "$GRAFANA_VOL")")
    log "  Including Grafana data: $GRAFANA_VOL"
fi

if [[ -n "$PROMETHEUS_VOL" && -d "$PROMETHEUS_VOL" ]]; then
    TAR_ARGS+=(-C "$(dirname "$PROMETHEUS_VOL")" "$(basename "$PROMETHEUS_VOL")")
    log "  Including Prometheus data: $PROMETHEUS_VOL"
fi

if [[ -n "$LOKI_VOL" && -d "$LOKI_VOL" ]]; then
    TAR_ARGS+=(-C "$(dirname "$LOKI_VOL")" "$(basename "$LOKI_VOL")")
    log "  Including Loki data: $LOKI_VOL"
fi

# Include exported dashboards
if [[ -d "$DASHBOARDS_DIR" ]]; then
    TAR_ARGS+=(-C "/tmp" "grafana-dashboards-${TIMESTAMP}")
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
    rm -rf "$DASHBOARDS_DIR"
    exit 1
fi

# Cleanup temp dashboards
rm -rf "$DASHBOARDS_DIR"

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

OLD_BACKUPS=$(ls -t "$BACKUP_DIR"/monitoring_backup_*.tar.gz 2>/dev/null | tail -n +$((RETENTION_COUNT + 1)) || true)
if [[ -n "$OLD_BACKUPS" ]]; then
    echo "$OLD_BACKUPS" | xargs rm -f
    log "Old backups cleaned up"
else
    log "No old backups to clean up"
fi

# Show current state
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/monitoring_backup_*.tar.gz 2>/dev/null | wc -l)
log "Total backups: $BACKUP_COUNT"

log "=========================================="
log "Monitoring Backup Completed: $(get_timestamp)"
log "=========================================="
