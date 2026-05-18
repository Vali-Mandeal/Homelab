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

update_config_files() {
    log_section "Updating Configuration Files"

    local target="/opt/monitoring"

    # docker-compose.yml - envsubst ${TRAEFIK_DOMAIN} at push time
    if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        local tmp_compose
        tmp_compose=$(mktemp --suffix=.yml)
        (
            set -a
            [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
            source "${SCRIPT_DIR}/config.env"
            set +a
            envsubst '${TRAEFIK_DOMAIN}' < "${SCRIPT_DIR}/docker-compose.yml" > "$tmp_compose"
        )
        pct push "$CT_ID" "$tmp_compose" "${target}/docker-compose.yml"
        rm -f "$tmp_compose"
        log_info "Updated docker-compose.yml"
    fi

    # Config files
    for f in loki-config.yaml prometheus.yml alloy-config.alloy; do
        if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
            pct push "$CT_ID" "${SCRIPT_DIR}/${f}" "${target}/${f}"
            log_info "Updated ${f}"
        fi
    done

    # Signal webhook config - substitute phone numbers from config.env
    if [[ -f "${SCRIPT_DIR}/signal-webhook-config.yaml" ]]; then
        local signal_tmp="/tmp/signal-webhook-config.yaml"
        sed "s|__SIGNAL_PHONE_NUMBER__|${SIGNAL_PHONE_NUMBER}|g; s|__SIGNAL_RECIPIENT__|${SIGNAL_RECIPIENT}|g" \
            "${SCRIPT_DIR}/signal-webhook-config.yaml" > "$signal_tmp"
        pct push "$CT_ID" "$signal_tmp" "${target}/signal-webhook-config.yaml"
        rm -f "$signal_tmp"
        log_info "Updated signal-webhook-config.yaml"
    fi

    # Grafana provisioning
    pct exec "$CT_ID" -- mkdir -p \
        "${target}/provisioning/datasources" \
        "${target}/provisioning/dashboards" \
        "${target}/provisioning/alerting"

    for prov_file in \
        provisioning/datasources/datasources.yaml \
        provisioning/dashboards/dashboards.yaml \
        provisioning/dashboards/homelab-overview.json \
        provisioning/dashboards/homelab-logs.json \
        provisioning/alerting/alerts.yaml; do
        if [[ -f "${SCRIPT_DIR}/${prov_file}" ]]; then
            pct push "$CT_ID" "${SCRIPT_DIR}/${prov_file}" "${target}/${prov_file}"
            log_info "Updated ${prov_file}"
        fi
    done

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
