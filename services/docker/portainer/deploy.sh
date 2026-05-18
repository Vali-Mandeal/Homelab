#!/usr/bin/env bash
# ==============================================================================
# Portainer - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys Portainer
# as the centralized container management server.
#
# After deployment, add agent environments via the Portainer UI:
#   Environments → Add Environment → Agent → <host_ip>:9001
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

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
    display_banner "Deploying Portainer (Centralized)"

    create_docker_lxc
    deploy_portainer_files
    start_portainer
    print_portainer_summary
}

# ==============================================================================
# Portainer Deployment
# ==============================================================================

deploy_portainer_files() {
    log_section "Deploying Portainer Configuration"

    local target="/opt/portainer"

    pct exec "$CT_ID" -- mkdir -p "$target"

    copy_file_to_container "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"

    log_info "Portainer files deployed"
}

copy_file_to_container() {
    local src="$1"
    local dest="$2"

    pct push "$CT_ID" "$src" "$dest"
}

# ==============================================================================
# Start Service
# ==============================================================================

start_portainer() {
    log_section "Starting Portainer"

    run_compose_in_container "portainer"

    # Wait for HTTPS port
    log_info "Waiting for Portainer to start (HTTPS 9443)..."
    local elapsed=0
    local timeout=30
    while [[ $elapsed -lt $timeout ]]; do
        if pct exec "$CT_ID" -- bash -c "curl -kfs -o /dev/null https://localhost:9443" 2>/dev/null; then
            log_info "Portainer is up on port 9443"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "Portainer did not respond on port 9443 within ${timeout}s (may still be starting)"
}

# ==============================================================================
# Summary
# ==============================================================================

print_portainer_summary() {
    log_section "Portainer Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo "  HTTPS:      https://${CT_IP}:9443"
    echo "  Traefik:    https://portainer.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  Post-deploy:"
    echo "    1. Set admin password on first login"
    echo "    2. Add agent environments:"
    echo "       Environments → Add Environment → Agent"
    echo "       URL format: <agent_host_ip>:9001"
    echo "       (See homelab.env / per-service config.env files for the IPs)"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
