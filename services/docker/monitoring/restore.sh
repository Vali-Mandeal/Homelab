#!/bin/bash

# Restore script for Monitoring Stack
# Restores Grafana + Prometheus + Loki data from a backup

set -euo pipefail

export TZ="Europe/Bucharest"

COMPOSE_DIR="/opt/monitoring"

# BACKUP_DIR comes from /opt/monitoring/.env (written by deploy.sh)
if [[ -f /opt/monitoring/.env ]]; then
    set -a; source /opt/monitoring/.env; set +a
fi
: "${BACKUP_DIR:?BACKUP_DIR not set - re-run monitoring deploy}"

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

BACKUPS=($(ls -t "$BACKUP_DIR"/monitoring_backup_*.tar.gz 2>/dev/null))

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
echo "WARNING: This will stop the monitoring stack and replace all data."
read -r -p "Continue? (y/N): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ==============================================================================
# Stop containers
# ==============================================================================

log "Stopping containers..."
cd "$COMPOSE_DIR"
docker compose down 2>&1

# ==============================================================================
# Restore volumes
# ==============================================================================

log "Restoring from backup..."

# Get volume mount points
GRAFANA_VOL=$(docker volume inspect monitoring_grafana-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")
PROMETHEUS_VOL=$(docker volume inspect monitoring_prometheus-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")
LOKI_VOL=$(docker volume inspect monitoring_loki-data -f '{{.Mountpoint}}' 2>/dev/null || echo "")

# Clear existing data
for vol in "$GRAFANA_VOL" "$PROMETHEUS_VOL" "$LOKI_VOL"; do
    if [[ -n "$vol" && -d "$vol" ]]; then
        rm -rf "${vol:?}"/*
        log "Cleared: $vol"
    fi
done

# Extract backup - the tar contains the volume directory names as they were
# We extract to a temp dir, then copy contents to the right volume paths
TEMP_DIR=$(mktemp -d)
tar -xzf "$SELECTED" -C "$TEMP_DIR"

# The backup contains directories named after the Docker volume mountpoint basenames
# Copy each back to the corresponding volume
for dir in "$TEMP_DIR"/*/; do
    dirname=$(basename "$dir")
    # Match by content heuristic - grafana has grafana.db, prometheus has chunks_head, etc.
    if [[ -f "${dir}grafana.db" ]] && [[ -n "$GRAFANA_VOL" ]]; then
        cp -a "${dir}"* "$GRAFANA_VOL/"
        log "Restored Grafana data"
    elif [[ -d "${dir}chunks_head" || -d "${dir}wal" ]] && [[ -n "$PROMETHEUS_VOL" ]]; then
        cp -a "${dir}"* "$PROMETHEUS_VOL/"
        log "Restored Prometheus data"
    elif [[ -d "${dir}chunks" ]] && [[ -n "$LOKI_VOL" ]]; then
        cp -a "${dir}"* "$LOKI_VOL/"
        log "Restored Loki data"
    elif [[ "$dirname" == grafana-dashboards-* ]]; then
        log "Dashboard exports found at: ${dir}"
        log "  Import manually via Grafana UI: Settings → JSON Model → paste"
    fi
done

rm -rf "$TEMP_DIR"

# ==============================================================================
# Start containers
# ==============================================================================

log "Starting containers..."
cd "$COMPOSE_DIR"
docker compose up -d

# Wait for Grafana
log "Waiting for Grafana..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:3001/api/health &>/dev/null; then
        success "Grafana is healthy"
        break
    fi
    sleep 2
done

success "Monitoring stack restored from: $(basename "$SELECTED")"
