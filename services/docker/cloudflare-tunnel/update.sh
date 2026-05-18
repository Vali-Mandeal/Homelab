#!/usr/bin/env bash
# ==============================================================================
# Cloudflare Tunnel - Update Script
# ==============================================================================
# Runs ON Proxmox. Updates the Cloudflare Tunnel LXC container:
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
    display_banner "Updating Cloudflare Tunnel"

    verify_container
    update_container_os
    pull_and_restart
    cleanup_images

    log_section "Cloudflare Tunnel Update Complete"
    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  Status:     Updated"
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

pull_and_restart() {
    log_section "Updating Docker Images"
    pct exec "$CT_ID" -- bash -c "cd /opt/cloudflare-tunnel && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd /opt/cloudflare-tunnel && docker compose up -d"
    log_info "Services restarted with new images"
}

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
}

main "$@"
