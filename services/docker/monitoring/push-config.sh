#!/usr/bin/env bash
# ==============================================================================
# Monitoring - config push helper (sourced by deploy.sh and update.sh)
# ==============================================================================
# Single writer for the rendered monitoring configs inside the LXC. Several
# files carry placeholders that must be filled before pushing:
#   docker-compose.yml   ${TRAEFIK_DOMAIN}                      (envsubst)
#   alloy-config.alloy   __LOG_PATH__                           (sed)
#   alerts.yaml          __TELEGRAM_BOT_TOKEN__/__TELEGRAM_CHAT_ID__ (sed)
# deploy.sh and update.sh used to each carry their own copy of this logic;
# update.sh's copy pushed alloy-config and alerts.yaml raw, silently breaking
# backup-log collection and Telegram alerting on every update.
#
# Requires: CT_ID, SCRIPT_DIR, DEPLOY_ROOT, CONTAINER_SSD_PATH, TELEGRAM_BOT_TOKEN,
# TELEGRAM_CHAT_ID (config.env), and a push function taking <src> <dest>.
# ==============================================================================

# push_monitoring_config <push_fn> <target_dir>
push_monitoring_config() {
    local push_fn="$1"
    local target="$2"
    local tmp

    pct exec "$CT_ID" -- mkdir -p \
        "${target}/provisioning/datasources" \
        "${target}/provisioning/dashboards" \
        "${target}/provisioning/alerting"

    # docker-compose.yml - envsubst reads the *process environment*, so re-source
    # with set -a in a subshell; only ${TRAEFIK_DOMAIN} is substituted.
    tmp=$(mktemp --suffix=.yml)
    (
        set -a
        [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
        source "${SCRIPT_DIR}/config.env"
        set +a
        envsubst '${TRAEFIK_DOMAIN}' < "${SCRIPT_DIR}/docker-compose.yml" > "$tmp"
    )
    "$push_fn" "$tmp" "${target}/docker-compose.yml"
    rm -f "$tmp"

    "$push_fn" "${SCRIPT_DIR}/loki-config.yaml" "${target}/loki-config.yaml"
    "$push_fn" "${SCRIPT_DIR}/prometheus.yml" "${target}/prometheus.yml"

    # alloy-config.alloy - __LOG_PATH__ is the backup-log glob on the SMB mount
    : "${CONTAINER_SSD_PATH:?CONTAINER_SSD_PATH must be set in config.env}"
    tmp=$(mktemp --suffix=.alloy)
    sed "s|__LOG_PATH__|/${CONTAINER_SSD_PATH}/monitoring/logs/*.log|g" \
        "${SCRIPT_DIR}/alloy-config.alloy" > "$tmp"
    "$push_fn" "$tmp" "${target}/alloy-config.alloy"
    rm -f "$tmp"

    local f
    for f in \
        provisioning/datasources/datasources.yaml \
        provisioning/dashboards/dashboards.yaml \
        provisioning/dashboards/homelab-overview.json \
        provisioning/dashboards/homelab-logs.json; do
        "$push_fn" "${SCRIPT_DIR}/${f}" "${target}/${f}"
    done

    # alerts.yaml - Telegram credentials from config.env (rendered file holds a
    # secret: mktemp keeps it out of a predictable /tmp path, removed right after)
    : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN must be set in config.env}"
    : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID must be set in config.env}"
    tmp=$(mktemp --suffix=.yaml)
    sed "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g; s|__TELEGRAM_CHAT_ID__|${TELEGRAM_CHAT_ID}|g" \
        "${SCRIPT_DIR}/provisioning/alerting/alerts.yaml" > "$tmp"
    "$push_fn" "$tmp" "${target}/provisioning/alerting/alerts.yaml"
    rm -f "$tmp"

    # Fail loudly rather than leave an unrendered placeholder live again.
    local left
    left=$(pct exec "$CT_ID" -- sh -c "cd '${target}' && grep -lE '__[A-Z_]+__|\\\$\\{TRAEFIK_DOMAIN\\}' docker-compose.yml alloy-config.alloy provisioning/alerting/alerts.yaml" 2>/dev/null || true)
    if [[ -n "$left" ]]; then
        log_error "Unrendered placeholders remain in: ${left}"
        return 1
    fi

    log_info "Monitoring configs pushed (compose, loki, prometheus, alloy, provisioning)"
}
