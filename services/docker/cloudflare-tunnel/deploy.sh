#!/usr/bin/env bash
# ==============================================================================
# Cloudflare Tunnel - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys tunnel.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/docker-service.sh"

# Load shared homelab config
if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

# Load service-specific config
source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Cloudflare Tunnel"

    validate_tunnel_config
    create_docker_lxc
    deploy_tunnel_files
    start_tunnel
    install_portainer_agent_in_container
    print_tunnel_summary
}

# ==============================================================================
# Validation
# ==============================================================================

validate_tunnel_config() {
    if [[ -z "${TUNNEL_TOKEN:-}" ]] || [[ "$TUNNEL_TOKEN" == "your-tunnel-token" ]]; then
        log_error "TUNNEL_TOKEN not set in config.env"
        log_info "Get your token from the Cloudflare Zero Trust dashboard"
        exit 1
    fi
}

# ==============================================================================
# Tunnel-Specific Deployment
# ==============================================================================

deploy_tunnel_files() {
    log_section "Deploying Cloudflare Tunnel Configuration"

    local target="/opt/cloudflare-tunnel"

    pct exec "$CT_ID" -- mkdir -p "$target"

    # Generate docker-compose.yml with token baked in
    generate_compose "$target"

    log_info "Tunnel files deployed"
}

generate_compose() {
    local target="$1"

    pct exec "$CT_ID" -- bash -c "cat > '${target}/docker-compose.yml'" <<EOF
services:
  cloudflare-tunnel:
    image: cloudflare/cloudflared:latest
    container_name: cloudflare-tunnel
    restart: unless-stopped
    security_opt:
      - apparmor:unconfined
    command: tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
    networks:
      - tunnel-net
    extra_hosts:
      - "host.docker.internal:host-gateway"

networks:
  tunnel-net:
    driver: bridge
EOF

    log_info "Generated docker-compose.yml with tunnel token"
}

# ==============================================================================
# Start Service
# ==============================================================================

start_tunnel() {
    log_section "Starting Cloudflare Tunnel"

    run_compose_in_container "cloudflare-tunnel"

    # Give it a moment to connect
    sleep 5

    # Check container is running
    if pct exec "$CT_ID" -- docker ps --format '{{.Names}}' | grep -q "cloudflare-tunnel"; then
        log_info "Cloudflare Tunnel container is running"
    else
        log_warn "Tunnel container may not have started - check logs:"
        log_warn "  pct exec ${CT_ID} -- docker logs cloudflare-tunnel"
    fi
}

# ==============================================================================
# Summary
# ==============================================================================

print_tunnel_summary() {
    log_section "Cloudflare Tunnel Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo ""
    echo "  Tunnel is connected to Cloudflare Zero Trust."
    echo "  Configure routes in the Cloudflare dashboard."
    echo ""
    echo "  View logs: pct exec ${CT_ID} -- docker logs -f cloudflare-tunnel"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
