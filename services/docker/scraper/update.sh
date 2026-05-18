#!/usr/bin/env bash
# ==============================================================================
# Scraper Stack - Update Script
# ==============================================================================
# Rebuilds the scraper API and admin UI from updated source. CT 121 stays as-is
# - no destroy/recreate. Use this for code changes; use deploy.sh only when you
# actually want to recreate the CT from scratch.
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
    display_banner "Updating Scraper Stack"

    ensure_ct_running
    update_container_os

    fetch_app_source

    update_scraper_source
    rebuild_scraper_image
    smoke_test
    restart_scraper_api

    update_admin_ui_source
    rebuild_admin_ui_image
    restart_admin_ui

    cleanup_images

    log_section "Scraper Stack Update Complete"
    echo "  API: http://${CT_IP}:${SCRAPER_PORT}  (scraper-api restarted)"
    echo "  UI:  http://${CT_IP}:${UI_PORT}       (scrapper-admin-ui restarted)"
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

# ==============================================================================
# Pre-flight
# ==============================================================================

ensure_ct_running() {
    local status
    status=$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')

    if [[ "$status" != "running" ]]; then
        log_error "CT ${CT_ID} (${CT_NAME}) is not running"
        exit 1
    fi

    log_info "CT ${CT_ID} is running"
}

update_container_os() {
    log_section "Applying OS Security Patches"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                                   DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
    log_info "OS packages updated"

    # apt-upgrade can replace iptables/netfilter and leave Docker referencing
    # chains that no longer exist; subsequent `docker run -p ...` then fails
    # with "iptables: No chain/target/match by that name". Restart Docker to
    # have it recreate its NAT/FORWARD chains; running containers come back
    # automatically via their --restart policy.
    log_info "Restarting Docker to refresh iptables rules"
    pct exec "$CT_ID" -- bash -c "systemctl restart docker"
    sleep 3
    log_info "Docker restarted"
}

# ==============================================================================
# Backend
# ==============================================================================

update_scraper_source() {
    log_section "Updating Scraper Source"

    pct exec "$CT_ID" -- rm -rf /opt/scraper/src
    pct exec "$CT_ID" -- mkdir -p /opt/scraper/src

    local tmp_tar="/tmp/scraper-src-$$.tar.gz"
    tar -czf "$tmp_tar" -C "${APP_SRC_DIR}/WebScrapper.ScraperApi" .
    pct push "$CT_ID" "$tmp_tar" "/tmp/scraper-src.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd /opt/scraper/src && tar -xzf /tmp/scraper-src.tar.gz && rm /tmp/scraper-src.tar.gz"
    rm -f "$tmp_tar"

    log_info "Source files updated"
}

rebuild_scraper_image() {
    log_section "Rebuilding Scraper Image"
    pct exec "$CT_ID" -- bash -c "docker build -t ${SCRAPER_IMAGE} /opt/scraper/src"
    log_info "Image rebuilt: ${SCRAPER_IMAGE}"
}

smoke_test() {
    log_section "Smoke Test"
    # Use a non-prod host port so the existing scraper-api on 8080 doesn't conflict.
    local smoke_port="18080"
    pct exec "$CT_ID" -- bash -c "docker rm -f scraper-smoke 2>/dev/null || true; docker run -d --name scraper-smoke -p ${smoke_port}:8080 ${SCRAPER_IMAGE}"

    # 120s: .NET + Playwright + Quartz cold-start can comfortably exceed 60s on this CT.
    if wait_for_service "$smoke_port" 120; then
        pct exec "$CT_ID" -- docker rm -f scraper-smoke
        log_info "Smoke test passed"
    else
        log_error "Smoke test failed - dumping container logs:"
        pct exec "$CT_ID" -- docker logs --tail 80 scraper-smoke 2>&1 || true
        pct exec "$CT_ID" -- docker rm -f scraper-smoke 2>/dev/null || true
        exit 1
    fi
}

restart_scraper_api() {
    log_section "Restarting Scraper API"

    if [[ -z "${MONGODB_URI:-}" ]]; then
        log_error "MONGODB_URI not set in homelab.env - cannot start scraper-api"
        exit 1
    fi

    local env_file="/tmp/scraper-api-env-$$"
    cat > "$env_file" <<EOF
DbSettings__MongoUrl=${MONGODB_URI}
DbSettings__DatabaseName=WebScrapperV2
TelegramSettings__BotToken=${TELEGRAM_BOT_TOKEN:-}
TelegramSettings__DefaultChatId=${TELEGRAM_DEFAULT_CHAT_ID:-}
EOF

    pct push "$CT_ID" "$env_file" "/opt/scraper/api.env"
    pct exec "$CT_ID" -- chmod 600 /opt/scraper/api.env
    rm -f "$env_file"

    pct exec "$CT_ID" -- bash -c "
        docker rm -f scraper-api 2>/dev/null || true
        docker run -d \
            --name scraper-api \
            --restart=unless-stopped \
            -p ${SCRAPER_PORT}:8080 \
            --env-file /opt/scraper/api.env \
            ${SCRAPER_IMAGE}
    "

    if wait_for_service "$SCRAPER_PORT" 120; then
        log_info "Scraper API running at http://${CT_IP}:${SCRAPER_PORT}"
    else
        log_error "scraper-api came up but did not respond on port ${SCRAPER_PORT} within 120s"
        log_error "Last 80 lines of scraper-api logs:"
        pct exec "$CT_ID" -- docker logs --tail 80 scraper-api 2>&1 || true
        exit 1
    fi
}

# ==============================================================================
# Admin UI
# ==============================================================================

update_admin_ui_source() {
    log_section "Updating Admin UI Source"

    local target="/opt/scrapper-admin"
    pct exec "$CT_ID" -- rm -rf "${target}/ui-src"
    pct exec "$CT_ID" -- mkdir -p "${target}/ui-src"

    local tmp_ui="/tmp/scrapper-admin-ui-$$.tar.gz"
    tar --exclude='./node_modules' --exclude='./dist' --exclude='./.vite' \
        -czf "$tmp_ui" -C "${APP_SRC_DIR}/frontend" .
    pct push "$CT_ID" "$tmp_ui" "/tmp/scrapper-admin-ui.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd ${target}/ui-src && tar -xzf /tmp/scrapper-admin-ui.tar.gz && rm /tmp/scrapper-admin-ui.tar.gz"
    rm -f "$tmp_ui"

    pct push "$CT_ID" "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"
    pct exec "$CT_ID" -- bash -c "cat > ${target}/.env << 'EOF'
UI_IMAGE=${UI_IMAGE}
UI_PORT=${UI_PORT}
EOF"

    log_info "Admin UI source updated"
}

rebuild_admin_ui_image() {
    log_section "Rebuilding Admin UI Image"
    pct exec "$CT_ID" -- bash -c "docker build --build-arg VITE_API_URL='${SCRAPER_API_URL}' -t ${UI_IMAGE} /opt/scrapper-admin/ui-src"
    log_info "UI image rebuilt: ${UI_IMAGE}"
}

restart_admin_ui() {
    log_section "Restarting Admin UI"
    pct exec "$CT_ID" -- bash -c "cd /opt/scrapper-admin && docker compose up -d"

    if wait_for_service "${UI_PORT}" 30; then
        log_info "Admin UI healthy"
    else
        log_error "Admin UI did not respond on port ${UI_PORT} within 30s"
        log_error "Last 30 lines of scrapper-admin-ui logs:"
        pct exec "$CT_ID" -- docker logs --tail 30 scrapper-admin-ui 2>&1 || true
        exit 1
    fi
}

# ==============================================================================
# Cleanup
# ==============================================================================

cleanup_images() {
    pct exec "$CT_ID" -- bash -c "docker image prune -f" 2>/dev/null || true
    log_info "Dangling images pruned"
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
