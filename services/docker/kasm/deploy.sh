#!/usr/bin/env bash
# ==============================================================================
# Kasm (Browser Isolation) - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys the
# Browser Isolation API that manages disposable Firefox containers.
#
# Extension compatible: works with the Kasm "Open in Isolation" extension.
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

# Where the fetched app source tree (cloned from SERVICE_REPO_URL) lives.
# The BrowserIsolation.Api/ subdir of this is what gets tarred and pushed
# into the CT as /opt/kasm/api/ - keeping docker-compose's `build: ./api`
# context unchanged.
APP_SRC_DIR="${SCRIPT_DIR}/.app-src"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Kasm (Browser Isolation)"

    fetch_app_source
    create_docker_lxc
    deploy_kasm_files
    prepull_browser_image
    start_kasm
    install_portainer_agent_in_container
    print_kasm_summary
}

# ==============================================================================
# App Source - fetched from GitHub
# ==============================================================================

fetch_app_source() {
    log_section "Fetching App Source"

    if [[ -z "${SERVICE_REPO_URL:-}" ]]; then
        log_error "SERVICE_REPO_URL not set in config.env - cannot fetch app source"
        exit 1
    fi

    fetch_service_source "$SERVICE_REPO_URL" "${SERVICE_REPO_REF:-main}" "$APP_SRC_DIR"
}

# ==============================================================================
# Deploy Files
# ==============================================================================

deploy_kasm_files() {
    log_section "Deploying Browser Isolation API"

    local target="/opt/kasm"

    pct exec "$CT_ID" -- mkdir -p "${target}/api"

    # Push API source code (from fetched repo) for Docker build
    local tmp_tar="/tmp/kasm-api-$$.tar.gz"
    tar -czf "$tmp_tar" -C "${APP_SRC_DIR}/BrowserIsolation.Api" .
    pct push "$CT_ID" "$tmp_tar" "/tmp/api.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd '${target}/api' && tar -xzf /tmp/api.tar.gz && rm /tmp/api.tar.gz"
    rm -f "$tmp_tar"

    # Push docker-compose (envsubst injects CT_IP).
    # envsubst reads the *process environment*, not shell vars - re-source with set -a
    # in a subshell so vars are exported only for this substitution.
    local tmp_compose
    tmp_compose=$(mktemp --suffix=.yml)
    (
        set -a
        [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
        source "${SCRIPT_DIR}/config.env"
        set +a
        envsubst '${CT_IP}' < "${SCRIPT_DIR}/docker-compose.yml" > "$tmp_compose"
    )
    pct push "$CT_ID" "$tmp_compose" "${target}/docker-compose.yml"
    rm -f "$tmp_compose"

    log_info "Browser Isolation API files deployed"
}

# ==============================================================================
# Pre-pull Browser Image
# ==============================================================================

prepull_browser_image() {
    log_section "Pre-pulling Browser Image"
    log_info "Pulling linuxserver/firefox (this may take a few minutes)..."
    pct exec "$CT_ID" -- docker pull lscr.io/linuxserver/firefox:latest
    log_info "Browser image ready"
}

# ==============================================================================
# Start Service
# ==============================================================================

start_kasm() {
    log_section "Starting Browser Isolation API"

    pct exec "$CT_ID" -- bash -c "cd /opt/kasm && docker compose up -d --build"

    wait_for_service 3000 120
}

# ==============================================================================
# Summary
# ==============================================================================

print_kasm_summary() {
    log_section "Kasm (Browser Isolation) Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo "  API:        http://${CT_IP}:3000"
    echo "  Traefik:    https://kasm.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  Extension:  Point 'Kasm Open in Isolation' at https://kasm.${TRAEFIK_DOMAIN}"
    echo "  Sessions:   Auto-destroyed after 30 minutes"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
