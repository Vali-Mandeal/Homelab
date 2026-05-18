#!/usr/bin/env bash
# ==============================================================================
# Traefik - Update Script
# ==============================================================================
# Runs ON Proxmox. Updates the Traefik LXC container:
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
    display_banner "Updating Traefik"

    verify_container
    update_container_os
    update_config_files
    pull_and_restart
    cleanup_images
    verify_healthy

    log_section "Traefik Update Complete"
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

    local target="/opt/traefik"

    # routes.yml uses ${VAR} placeholders for every backend IP (PROXMOX_HOST_IP,
    # SCRAPER_CT_IP, etc.). Traefik's file provider does NOT do env substitution,
    # so we must envsubst before pushing - otherwise routes silently break with
    # literal "${SCRAPER_CT_IP}" backend URLs.
    if [[ -f "${SCRIPT_DIR}/routes.yml" ]]; then
        local tmp_routes
        tmp_routes=$(mktemp --suffix=.yml)
        (
            set -a
            [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
            source "${SCRIPT_DIR}/config.env"
            set +a
            envsubst < "${SCRIPT_DIR}/routes.yml" > "$tmp_routes"
        )

        # Sanity check: any unsubstituted ${VAR} means a config var is missing.
        if grep -q '\${' "$tmp_routes"; then
            log_error "routes.yml still contains unsubstituted variables after envsubst:"
            grep -n '\${' "$tmp_routes" | head -5
            rm -f "$tmp_routes"
            exit 1
        fi

        pct push "$CT_ID" "$tmp_routes" "${target}/data/routes.yml"
        rm -f "$tmp_routes"
        log_info "Updated routes.yml (with env substitution)"
    fi

    # Update docker-compose.yml
    if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        pct push "$CT_ID" "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"
        log_info "Updated docker-compose.yml"
    fi

    log_info "Configuration files updated"
}

pull_and_restart() {
    log_section "Updating Docker Images"
    pct exec "$CT_ID" -- bash -c "cd /opt/traefik && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd /opt/traefik && docker compose up -d"

    # Ensure Docker's NAT/masquerade rules are intact (can be lost after apt upgrade restarts Docker)
    if ! pct exec "$CT_ID" -- iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q MASQUERADE; then
        log_info "Docker NAT rules missing - restarting Docker to restore..."
        pct exec "$CT_ID" -- systemctl restart docker
        sleep 3
        pct exec "$CT_ID" -- bash -c "cd /opt/traefik && docker compose up -d"
    fi

    log_info "Services restarted with new images"
}

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
}

verify_healthy() {
    log_info "Waiting for Traefik on port 80 (timeout: 30s)..."

    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        # Traefik redirects HTTP→HTTPS so a 301 is healthy. Use -o /dev/null -w to check HTTP code.
        local code
        code=$(pct exec "$CT_ID" -- bash -c "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 http://localhost:80" 2>/dev/null) || true
        if [[ -n "$code" ]] && [[ "$code" != "000" ]]; then
            log_info "Traefik is up on port 80 (HTTP ${code})"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "Traefik did not respond on port 80 within 30s (may still be starting)"
}

main "$@"
