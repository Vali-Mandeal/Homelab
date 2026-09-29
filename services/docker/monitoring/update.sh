#!/usr/bin/env bash
# ==============================================================================
# Monitoring Stack - Update Script
# ==============================================================================
# Runs ON Proxmox. Updates the Monitoring LXC container:
#   1. OS security patches (apt upgrade)
#   2. Sync config files
#   3. Pull new Docker images
#   4. Restart services
#   5. Clean up old images
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/docker-service.sh"
source "${SCRIPT_DIR}/push-config.sh"

if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Updating Monitoring Stack"

    verify_container
    update_container_os
    update_config_files
    pull_and_restart
    cleanup_images
    verify_healthy

    log_section "Monitoring Update Complete"
    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  Status:     Healthy"
    echo ""
}

verify_container() {
    log_info "Verifying container ${CT_ID} is running..."
    if ! pct status "$CT_ID" 2>/dev/null | grep -q "running"; then
        log_error "Container ${CT_ID} (${CT_NAME}) is not running"
        exit 1
    fi
    log_info "Container is running"
}

update_container_os() {
    log_section "Applying OS Security Patches"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                                   DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
    log_info "OS packages updated"
}

pct_push_file() {
    pct push "$CT_ID" "$1" "$2"
}

update_config_files() {
    log_section "Updating Configuration Files"

    local target="/opt/monitoring"

    # Compose, Loki/Prometheus/Alloy configs and Grafana provisioning - rendered
    # and pushed by the shared helper (same one deploy.sh uses)
    push_monitoring_config pct_push_file "$target"

    # Signal webhook config - substitute phone numbers from config.env
    if [[ -f "${SCRIPT_DIR}/signal-webhook-config.yaml" ]]; then
        local signal_tmp="/tmp/signal-webhook-config.yaml"
        sed "s|__SIGNAL_PHONE_NUMBER__|${SIGNAL_PHONE_NUMBER}|g; s|__SIGNAL_RECIPIENT__|${SIGNAL_RECIPIENT}|g" \
            "${SCRIPT_DIR}/signal-webhook-config.yaml" > "$signal_tmp"
        pct push "$CT_ID" "$signal_tmp" "${target}/signal-webhook-config.yaml"
        rm -f "$signal_tmp"
        log_info "Updated signal-webhook-config.yaml"
    fi

    # Backup/restore scripts
    for script in nightly-backup.sh restore.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            pct push "$CT_ID" "${SCRIPT_DIR}/${script}" "/opt/monitoring/${script}"
            pct exec "$CT_ID" -- chmod +x "/opt/monitoring/${script}"
            log_info "Updated ${script}"
        fi
    done

    log_info "Configuration files updated"
}

pull_and_restart() {
    log_section "Updating Docker Images"
    pct exec "$CT_ID" -- bash -c "cd /opt/monitoring && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd /opt/monitoring && docker compose up -d"
    log_info "Services restarted with new images"
}

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
}

verify_healthy() {
    wait_for_service "${GRAFANA_PORT}" 60
}

main "$@"
