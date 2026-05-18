#!/usr/bin/env bash
# ==============================================================================
# Kasm (Browser Isolation) - Update Script
# ==============================================================================
# Runs ON Proxmox. Updates the Browser Isolation LXC container:
#   1. OS security patches (apt upgrade)
#   2. Push updated API source code and docker-compose.yml
#   3. Rebuild and restart the API container
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

# Where the fetched app source tree (cloned from SERVICE_REPO_URL) lives.
APP_SRC_DIR="${SCRIPT_DIR}/.app-src"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Updating Kasm (Browser Isolation)"

    verify_container
    ensure_docker_nat
    update_container_os
    fetch_app_source
    update_kasm_files
    rebuild_and_restart
    cleanup_images
    verify_healthy

    log_section "Kasm Update Complete"
    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  API:        http://${CT_IP}:3000"
    echo "  Traefik:    https://kasm.${TRAEFIK_DOMAIN}"
    echo ""
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

verify_container() {
    log_info "Verifying container ${CT_ID} is running..."
    if ! pct status "$CT_ID" 2>/dev/null | grep -q "running"; then
        log_error "Container ${CT_ID} (${CT_NAME}) is not running"
        exit 1
    fi
    log_info "Container is running"
}

ensure_docker_nat() {
    if ! pct exec "$CT_ID" -- iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q MASQUERADE; then
        log_info "Docker NAT rules missing - restarting Docker to restore..."
        pct exec "$CT_ID" -- systemctl restart docker
        sleep 3
    fi
}

update_container_os() {
    log_section "Applying OS Security Patches"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                                   DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
    log_info "OS packages updated"
}

update_kasm_files() {
    log_section "Updating Browser Isolation API Files"

    local target="/opt/kasm"

    # Wipe stale api/ then push fresh source from the fetched repo. Without
    # the wipe, files removed upstream linger and confuse the docker build.
    pct exec "$CT_ID" -- rm -rf "${target}/api"
    pct exec "$CT_ID" -- mkdir -p "${target}/api"

    local tmp_tar="/tmp/kasm-api-$$.tar.gz"
    tar -czf "$tmp_tar" -C "${APP_SRC_DIR}/BrowserIsolation.Api" .
    pct push "$CT_ID" "$tmp_tar" "/tmp/api.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd '${target}/api' && tar -xzf /tmp/api.tar.gz && rm /tmp/api.tar.gz"
    rm -f "$tmp_tar"
    log_info "Updated API source code"

    # docker-compose.yml uses ${CT_IP} - must envsubst, otherwise we'd push
    # a literal "${CT_IP}" string and the API would advertise the wrong host
    # for spawned containers.
    local tmp_compose
    tmp_compose=$(mktemp --suffix=.yml)
    (
        set -a
        [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
        source "${SCRIPT_DIR}/config.env"
        set +a
        envsubst '${CT_IP}' < "${SCRIPT_DIR}/docker-compose.yml" > "$tmp_compose"
    )

    if grep -q '\${' "$tmp_compose"; then
        log_error "docker-compose.yml still contains unsubstituted variables after envsubst:"
        grep -n '\${' "$tmp_compose" | head -5
        rm -f "$tmp_compose"
        exit 1
    fi

    pct push "$CT_ID" "$tmp_compose" "${target}/docker-compose.yml"
    rm -f "$tmp_compose"
    log_info "Updated docker-compose.yml (with env substitution)"
}

rebuild_and_restart() {
    log_section "Rebuilding and Restarting API"
    pct exec "$CT_ID" -- bash -c "cd /opt/kasm && docker compose up -d --build"
    log_info "API rebuilt and restarted"
}

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
}

verify_healthy() {
    log_info "Waiting for API on port 3000 (timeout: 60s)..."

    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        local code
        code=$(pct exec "$CT_ID" -- bash -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3000" 2>/dev/null) || true
        if [[ "$code" == "200" ]]; then
            log_info "Browser Isolation API is up on port 3000"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_error "API did not respond on port 3000 within 60s"
    log_error "Last 30 lines of browser-isolation logs:"
    pct exec "$CT_ID" -- bash -c "cd /opt/kasm && docker compose logs --tail 30 browser-isolation 2>&1" || true
    exit 1
}

main "$@"
