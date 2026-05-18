#!/usr/bin/env bash
# ==============================================================================
# n8n - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys
# n8n + Postgres. Data stored in Docker volumes; backups go to private NAS.
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
    display_banner "Deploying n8n"

    create_docker_lxc
    setup_backup_storage
    deploy_n8n_files
    create_env_file
    start_n8n
    setup_backup_cron
    install_portainer_agent_in_container
    print_n8n_summary
}

# ==============================================================================
# Backup Storage - Bind mount private NAS share into container
# ==============================================================================

setup_backup_storage() {
    log_section "Setting Up Backup Storage"

    if ! mountpoint -q "$PROXMOX_PRIVATE_PATH" 2>/dev/null; then
        log_error "SMB mount not found at ${PROXMOX_PRIVATE_PATH}. Run proxmox-dr first!"
        exit 1
    fi
    log_info "SMB mount OK: ${PROXMOX_PRIVATE_PATH}"

    mkdir -p "${PROXMOX_PRIVATE_PATH}/private/n8n/backups" \
             "${PROXMOX_PRIVATE_PATH}/private/n8n/logs"

    setup_uid_mapping
    setup_lxc_bind_mount "$PROXMOX_PRIVATE_PATH" "/${CONTAINER_PRIVATE_PATH}"
    setup_nas_user
}

setup_nas_user() {
    log_info "Creating NAS service user (UID ${NAS_SMB_UID}) in container..."

    pct exec "$CT_ID" -- bash -c "
        if ! id -u n8n-backup &>/dev/null; then
            groupadd -g ${NAS_SMB_UID} n8n-backup
            useradd -u ${NAS_SMB_UID} -g ${NAS_SMB_UID} -M -s /bin/bash n8n-backup
        fi
        usermod -aG docker n8n-backup
    "

    log_info "NAS user configured"
}

# ==============================================================================
# n8n Deployment
# ==============================================================================

deploy_n8n_files() {
    log_section "Deploying n8n Configuration"

    local target="/opt/n8n"
    pct exec "$CT_ID" -- mkdir -p "${target}"

    # docker-compose.yml contains ${TRAEFIK_DOMAIN} which must be substituted at
    # push time (Docker Compose can only resolve from a sibling .env, and we
    # don't want to leak the domain into the runtime .env). The other ${VAR}
    # placeholders (DB_PASSWORD etc.) stay literal for Compose to resolve.
    local tmp_compose
    tmp_compose=$(mktemp --suffix=.yml)
    (
        set -a
        [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
        source "${SCRIPT_DIR}/config.env"
        set +a
        envsubst '${TRAEFIK_DOMAIN}' < "${SCRIPT_DIR}/docker-compose.yml" > "$tmp_compose"
    )
    pct push "$CT_ID" "$tmp_compose" "${target}/docker-compose.yml"
    rm -f "$tmp_compose"

    pct push "$CT_ID" "${SCRIPT_DIR}/nightly-backup.sh"  "${target}/nightly-backup.sh"
    pct push "$CT_ID" "${SCRIPT_DIR}/restore.sh"         "${target}/restore.sh"
    pct exec "$CT_ID" -- chmod +x "${target}/nightly-backup.sh" "${target}/restore.sh"

    log_info "n8n files deployed"
}

create_env_file() {
    log_info "Creating .env file in container..."

    pct exec "$CT_ID" -- bash -c "cat > /opt/n8n/.env << 'EOF'
N8N_PORT=${N8N_PORT}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
DB_PASSWORD=${DB_PASSWORD}
BACKUP_DIR=/${CONTAINER_PRIVATE_PATH}/private/n8n/backups
LOG_DIR=/${CONTAINER_PRIVATE_PATH}/private/n8n/logs
EOF"

    log_info ".env file created"
}

# ==============================================================================
# Start Services
# ==============================================================================

start_n8n() {
    log_section "Starting n8n"

    run_compose_in_container "n8n"
    wait_for_service "$N8N_PORT" 90
}

# ==============================================================================
# Nightly Backup Cron
# ==============================================================================

setup_backup_cron() {
    log_info "Setting up nightly backup cron (3:00 AM) as n8n-backup user..."

    pct exec "$CT_ID" -- bash -c '
        CRON_JOB="0 3 * * * /opt/n8n/nightly-backup.sh"
        (crontab -u n8n-backup -l 2>/dev/null | grep -v "nightly-backup.sh"; echo "$CRON_JOB") | crontab -u n8n-backup -
    '

    log_info "Nightly backup scheduled at 3:00 AM (as n8n-backup user)"
}

# ==============================================================================
# Summary
# ==============================================================================

print_n8n_summary() {
    log_section "n8n Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo ""
    echo "  n8n:        http://${CT_IP}:${N8N_PORT}"
    echo "  URL:        https://n8n.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  First run: n8n will prompt you to create an admin account."
    echo ""
    echo "  Backup:"
    echo "    Schedule:   Nightly at 3:00 AM"
    echo "    Location:   /${CONTAINER_PRIVATE_PATH}/private/n8n/backups"
    echo "    Retention:  7 backups"
    echo "    Restore:    /opt/n8n/restore.sh"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
