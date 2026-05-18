#!/usr/bin/env bash
# ==============================================================================
# Traefik Reverse Proxy - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys Traefik.
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
    display_banner "Deploying Traefik"

    create_docker_lxc
    deploy_traefik_files
    start_traefik
    install_portainer_agent_in_container
    print_traefik_summary
}

# ==============================================================================
# Traefik-Specific Deployment
# ==============================================================================

deploy_traefik_files() {
    log_section "Deploying Traefik Configuration"

    local target="/opt/traefik"

    # Create directory structure
    pct exec "$CT_ID" -- mkdir -p "${target}/data"

    # Generate .env with secrets
    generate_traefik_env "$target"

    # Generate traefik.yml with resolved values
    generate_traefik_config "$target"

    # Copy static files
    copy_file_to_container "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"

    # routes.yml uses ${VAR} placeholders for every backend IP - substitute via envsubst.
    # Variables come from homelab.env (PROXMOX_HOST_IP, NAS_PRIVATE_IP, GATEWAY_IP,
    # PORTAINER_SERVER_IP) and traefik's own config.env (per-service backend IPs).
    # envsubst reads the *process environment*, not shell vars - re-source with set -a
    # in a subshell so vars are exported only for this substitution.
    local tmp_routes
    tmp_routes=$(mktemp --suffix=.yml)
    (
        set -a
        [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
        source "${SCRIPT_DIR}/config.env"
        set +a
        envsubst < "${SCRIPT_DIR}/routes.yml" > "$tmp_routes"
    )
    copy_file_to_container "$tmp_routes" "${target}/data/routes.yml"
    rm -f "$tmp_routes"

    # Create acme.json with correct permissions
    pct exec "$CT_ID" -- bash -c "touch '${target}/data/acme.json' && chmod 600 '${target}/data/acme.json'"

    log_info "Traefik files deployed"
}

generate_traefik_env() {
    local target="$1"

    pct exec "$CT_ID" -- bash -c "cat > '${target}/.env'" <<EOF
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
CLOUDFLARE_DNS_API_TOKEN=${CLOUDFLARE_DNS_API_TOKEN}
TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL}
EOF

    log_info "Generated .env with Cloudflare credentials"
}

generate_traefik_config() {
    local target="$1"

    pct exec "$CT_ID" -- bash -c "cat > '${target}/traefik.yml'" <<EOF
api:
  dashboard: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

certificatesResolvers:
  cloudflare:
    acme:
      email: "${TRAEFIK_ACME_EMAIL}"
      storage: /data/acme.json
      dnsChallenge:
        provider: cloudflare
        delayBeforeCheck: 30
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"

providers:
  docker:
    exposedByDefault: false
    network: traefik-net
  file:
    filename: /data/routes.yml
    watch: true

log:
  level: INFO
EOF

    log_info "Generated traefik.yml"
}

copy_file_to_container() {
    local src="$1"
    local dest="$2"

    pct push "$CT_ID" "$src" "$dest"
}

# ==============================================================================
# Start Service
# ==============================================================================

start_traefik() {
    log_section "Starting Traefik"

    run_compose_in_container "traefik"
    wait_for_service 80 30
}

# ==============================================================================
# Summary
# ==============================================================================

print_traefik_summary() {
    log_section "Traefik Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo "  HTTP:       http://${CT_IP}:80"
    echo "  HTTPS:      https://${CT_IP}:443"
    echo "  Dashboard:  https://traefik.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  Routes file: /opt/traefik/data/routes.yml (hot-reload enabled)"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
