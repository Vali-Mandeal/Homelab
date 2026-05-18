#!/usr/bin/env bash
# ==============================================================================
# Homepage - Update Script
# ==============================================================================
# Runs ON Proxmox. Updates the Homepage LXC container:
#   1. OS security patches (apt upgrade)
#   2. Pull new Docker images
#   3. Restart services
#   4. Clean up old images
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
    display_banner "Updating Homepage"

    verify_container
    update_container_os
    update_config_files
    pull_and_restart
    cleanup_images
    verify_healthy

    log_section "Homepage Update Complete"
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

    local target="/opt/homepage"

    # Update docker-compose.yml
    if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        pct push "$CT_ID" "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"
        log_info "Updated docker-compose.yml"
    fi

    # Update config YAML files
    for f in settings.yaml services.yaml widgets.yaml bookmarks.yaml docker.yaml; do
        if [[ -f "${SCRIPT_DIR}/config/${f}" ]]; then
            pct push "$CT_ID" "${SCRIPT_DIR}/config/${f}" "${target}/config/${f}"
            log_info "Updated ${f}"
        fi
    done

    # Update custom CSS
    if [[ -f "${SCRIPT_DIR}/config/custom.css" ]]; then
        pct push "$CT_ID" "${SCRIPT_DIR}/config/custom.css" "${target}/config/custom.css"
        log_info "Updated custom.css"
    fi

    # Update images (logo, wallpaper)
    if [[ -f "${SCRIPT_DIR}/logo.jpg" ]]; then
        pct push "$CT_ID" "${SCRIPT_DIR}/logo.jpg" "${target}/images/logo.jpg"
    fi
    if [[ -f "${SCRIPT_DIR}/wallpaper.jpg" ]]; then
        pct push "$CT_ID" "${SCRIPT_DIR}/wallpaper.jpg" "${target}/images/wallpaper.jpg"
    fi

    log_info "Configuration files updated"
}

pull_and_restart() {
    log_section "Updating Docker Images"
    pct exec "$CT_ID" -- bash -c "cd /opt/homepage && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd /opt/homepage && docker compose up -d"
    log_info "Services restarted with new images"
}

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
}

verify_healthy() {
    wait_for_service 3000 30
}

main "$@"
