#!/usr/bin/env bash
# ==============================================================================
# n8n - Update Script
# ==============================================================================
# Runs ON Proxmox. Updates the n8n LXC container:
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
    display_banner "Updating n8n"

    verify_container
    update_container_os
    update_config_files
    pull_and_restart
    cleanup_images
    verify_healthy

    log_section "n8n Update Complete"
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

    local target="/opt/n8n"

    # docker-compose.yml contains ${TRAEFIK_DOMAIN} which must be substituted at
    # push time. Other ${VAR}s stay literal for Docker Compose to resolve at runtime.
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

    for script in nightly-backup.sh restore.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            pct push "$CT_ID" "${SCRIPT_DIR}/${script}" "${target}/${script}"
            pct exec "$CT_ID" -- chmod +x "${target}/${script}"
            log_info "Updated ${script}"
        fi
    done

    log_info "Configuration files updated"
}

pull_and_restart() {
    log_section "Updating Docker Images"
    pct exec "$CT_ID" -- bash -c "cd /opt/n8n && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd /opt/n8n && docker compose up -d"
    log_info "Services restarted with new images"
}

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
}

verify_healthy() {
    wait_for_service "${N8N_PORT}" 90
}

main "$@"
