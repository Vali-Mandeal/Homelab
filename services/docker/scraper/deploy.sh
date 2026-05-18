#!/usr/bin/env bash
# ==============================================================================
# Scraper Stack - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC CT 121, installs Docker, then builds and starts
# both the .NET ScraperApi (BE) and the Admin UI (FE) inside the same CT.
#
# CT 121 is the home of the whole scraper stack - BE + FE deploy together so
# a fresh CT (current `create_docker_lxc` recreates it) never leaves the FE
# behind.
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
# Populated by fetch_app_source(); subdirs WebScrapper.ScraperApi/ and frontend/
# are then tarred and pushed into the CT.
APP_SRC_DIR="${SCRIPT_DIR}/.app-src"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Scraper Stack (CT ${CT_ID})"

    fetch_app_source

    create_docker_lxc

    deploy_scraper_files
    build_scraper_image
    smoke_test
    start_scraper_api

    deploy_admin_ui_files
    build_admin_ui_image
    start_admin_ui

    print_summary
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
# Backend - files, build, smoke, start
# ==============================================================================

deploy_scraper_files() {
    log_section "Deploying Scraper Files"

    pct exec "$CT_ID" -- mkdir -p /opt/scraper/src

    local tmp_tar="/tmp/scraper-src-$$.tar.gz"
    tar -czf "$tmp_tar" -C "${APP_SRC_DIR}/WebScrapper.ScraperApi" .
    pct push "$CT_ID" "$tmp_tar" "/tmp/scraper-src.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd /opt/scraper/src && tar -xzf /tmp/scraper-src.tar.gz && rm /tmp/scraper-src.tar.gz"
    rm -f "$tmp_tar"

    log_info "Scraper source deployed"
}

build_scraper_image() {
    log_section "Building Scraper Image (this takes a few minutes)"

    pct exec "$CT_ID" -- bash -c "docker build -t ${SCRAPER_IMAGE} /opt/scraper/src"

    log_info "Image built: ${SCRAPER_IMAGE}"
}

smoke_test() {
    log_section "Smoke Test"

    # Use a non-prod host port so a refresh-mode redeploy (where scraper-api on
    # 8080 is still running) doesn't fail with a port-allocation conflict.
    local smoke_port="18080"
    pct exec "$CT_ID" -- bash -c "docker rm -f scraper-smoke 2>/dev/null || true; docker run -d --name scraper-smoke -p ${smoke_port}:8080 ${SCRAPER_IMAGE}"

    # 120s: .NET + Playwright + Quartz cold-start can comfortably exceed 60s.
    if wait_for_service "$smoke_port" 120; then
        pct exec "$CT_ID" -- docker rm -f scraper-smoke
        log_info "Smoke test passed - scraper API is healthy"
    else
        log_error "Smoke test failed - dumping container logs:"
        pct exec "$CT_ID" -- docker logs --tail 80 scraper-smoke 2>&1 || true
        pct exec "$CT_ID" -- docker rm -f scraper-smoke 2>/dev/null || true
        exit 1
    fi
}

start_scraper_api() {
    log_section "Starting Scraper API (production)"

    if [[ -z "${MONGODB_URI:-}" ]]; then
        log_error "MONGODB_URI not set in homelab.env - cannot start scraper-api"
        exit 1
    fi

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        log_warn "TELEGRAM_BOT_TOKEN not set in homelab.env - Telegram notifications disabled"
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
# Admin UI - files, build, start (compose)
# ==============================================================================

deploy_admin_ui_files() {
    log_section "Deploying Admin UI Files"

    local target="/opt/scrapper-admin"
    pct exec "$CT_ID" -- mkdir -p "${target}/ui-src"

    pct push "$CT_ID" "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"
    pct exec "$CT_ID" -- bash -c "cat > ${target}/.env << 'EOF'
UI_IMAGE=${UI_IMAGE}
UI_PORT=${UI_PORT}
EOF"

    local tmp_ui="/tmp/scrapper-admin-ui-$$.tar.gz"
    tar --exclude='./node_modules' --exclude='./dist' --exclude='./.vite' \
        -czf "$tmp_ui" -C "${APP_SRC_DIR}/frontend" .
    pct push "$CT_ID" "$tmp_ui" "/tmp/scrapper-admin-ui.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd ${target}/ui-src && tar -xzf /tmp/scrapper-admin-ui.tar.gz && rm /tmp/scrapper-admin-ui.tar.gz"
    rm -f "$tmp_ui"

    log_info "Admin UI source deployed"
}

build_admin_ui_image() {
    log_section "Building Admin UI Image (this takes a minute)"

    pct exec "$CT_ID" -- bash -c "docker build --build-arg VITE_API_URL='${SCRAPER_API_URL}' -t ${UI_IMAGE} /opt/scrapper-admin/ui-src"

    log_info "UI image built: ${UI_IMAGE}  (API base baked in: ${SCRAPER_API_URL})"
}

start_admin_ui() {
    log_section "Starting Admin UI"

    pct exec "$CT_ID" -- bash -c "cd /opt/scrapper-admin && docker compose up -d"

    if wait_for_service "${UI_PORT}" 30; then
        log_info "Admin UI is healthy"
    else
        log_error "Admin UI did not respond on port ${UI_PORT} within 30s"
        log_error "Last 30 lines of scrapper-admin-ui logs:"
        pct exec "$CT_ID" -- docker logs --tail 30 scrapper-admin-ui 2>&1 || true
        exit 1
    fi
}

# ==============================================================================
# Summary
# ==============================================================================

print_summary() {
    log_section "Scraper Stack Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})  - RUNNING (24/7)"
    echo "  IP:         ${CT_IP}"
    echo ""
    echo "  API:        http://${CT_IP}:${SCRAPER_PORT}        (scraper-api)"
    echo "  UI:         http://${CT_IP}:${UI_PORT}             (scrapper-admin-ui)"
    echo "  Traefik:    https://scrapper-admin.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  API base baked into FE bundle: ${SCRAPER_API_URL}"
    echo ""
    echo "  Update:  ./update.sh"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
