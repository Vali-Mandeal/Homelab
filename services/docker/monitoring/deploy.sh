#!/usr/bin/env bash
# ==============================================================================
# Monitoring Stack - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys
# Grafana + Prometheus + Loki + Alloy.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/docker-service.sh"
source "${SCRIPT_DIR}/push-config.sh"

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
    display_banner "Deploying Monitoring Stack"

    create_docker_lxc
    setup_backup_storage
    deploy_monitoring_files
    deploy_backup_scripts
    create_env_file
    start_monitoring
    setup_backup_cron
    install_portainer_agent_in_container
    print_monitoring_summary
}

# ==============================================================================
# Backup Storage - Bind mount NAS SMB share into container
# ==============================================================================

setup_backup_storage() {
    log_section "Setting Up Backup Storage"

    if ! mountpoint -q "$PROXMOX_SSD_PATH" 2>/dev/null; then
        log_error "SMB mount not found at ${PROXMOX_SSD_PATH}. Run proxmox-dr first!"
        exit 1
    fi
    log_info "SMB mount OK: ${PROXMOX_SSD_PATH}"

    # Create subdirectories on Proxmox host (before bind mount)
    mkdir -p "${PROXMOX_SSD_PATH}/monitoring/backups" \
             "${PROXMOX_SSD_PATH}/monitoring/logs"

    # Add UID/GID mapping so container processes can write to SMB mount
    # (mounted with uid=${NAS_SMB_UID} on Proxmox).
    setup_uid_mapping

    setup_lxc_bind_mount "$PROXMOX_SSD_PATH" "/${CONTAINER_SSD_PATH}"

    # Create a service user with that UID inside the container for NAS writes.
    setup_nas_user
}

setup_nas_user() {
    log_info "Creating NAS service user (UID ${NAS_SMB_UID}) in container..."

    pct exec "$CT_ID" -- bash -c "
        if ! id -u monitoring &>/dev/null; then
            groupadd -g ${NAS_SMB_UID} monitoring
            useradd -u ${NAS_SMB_UID} -g ${NAS_SMB_UID} -M -s /bin/bash monitoring
        fi
        # Allow running docker commands for backups
        usermod -aG docker monitoring
    "

    log_info "NAS user configured"
}

# ==============================================================================
# Monitoring-Specific Deployment
# ==============================================================================

deploy_monitoring_files() {
    log_section "Deploying Monitoring Configuration"

    local target="/opt/monitoring"

    # Compose, Loki/Prometheus/Alloy configs and Grafana provisioning - rendered
    # and pushed by the shared helper (same one update.sh uses)
    push_monitoring_config copy_file_to_container "$target"

    log_info "Monitoring files deployed"
}

copy_file_to_container() {
    local src="$1"
    local dest="$2"

    pct push "$CT_ID" "$src" "$dest"
}

deploy_backup_scripts() {
    log_info "Deploying backup and restore scripts..."

    for script in nightly-backup.sh restore.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            copy_file_to_container "${SCRIPT_DIR}/${script}" "/opt/monitoring/${script}"
            pct exec "$CT_ID" -- chmod +x "/opt/monitoring/${script}"
        fi
    done

    log_info "Backup scripts deployed"
}

create_env_file() {
    log_info "Creating .env file in container..."

    pct exec "$CT_ID" -- bash -c "cat > /opt/monitoring/.env << 'EOF'
GRAFANA_PORT=${GRAFANA_PORT}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
PROMETHEUS_PORT=${PROMETHEUS_PORT}
LOKI_PORT=${LOKI_PORT}
BACKUP_DIR=/${CONTAINER_SSD_PATH}/monitoring/backups
LOG_DIR=/${CONTAINER_SSD_PATH}/monitoring/logs
EOF"

    log_info ".env file created"
}

# ==============================================================================
# Start Services
# ==============================================================================

start_monitoring() {
    log_section "Starting Monitoring Stack"

    run_compose_in_container "monitoring"

    # Wait for Grafana to be ready
    wait_for_service "$GRAFANA_PORT" 60
}

# ==============================================================================
# Nightly Backup Cron
# ==============================================================================

setup_backup_cron() {
    log_info "Setting up nightly backup cron (4:00 AM) as monitoring user..."

    # Run backup as the monitoring user (created with UID=${NAS_SMB_UID}) so it can write to the NAS mount
    pct exec "$CT_ID" -- bash -c '
        CRON_JOB="0 4 * * * /opt/monitoring/nightly-backup.sh"
        (crontab -u monitoring -l 2>/dev/null | grep -v "nightly-backup.sh"; echo "$CRON_JOB") | crontab -u monitoring -
    '

    log_info "Nightly backup scheduled at 4:00 AM (as monitoring user)"
}

# ==============================================================================
# Summary
# ==============================================================================

print_monitoring_summary() {
    log_section "Monitoring Stack Deployed Successfully"

    echo "  Container:    ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:           ${CT_IP}"
    echo ""
    echo "  Grafana:      http://${CT_IP}:${GRAFANA_PORT}"
    echo "  Prometheus:   http://${CT_IP}:${PROMETHEUS_PORT}"
    echo "  Loki:         http://${CT_IP}:${LOKI_PORT}"
    echo "  Alloy:        http://${CT_IP}:12345"
    echo ""
    echo "  Grafana Login:"
    echo "    Username:   admin"
    echo "    Password:   ${GRAFANA_ADMIN_PASSWORD}"
    echo ""
    echo "  Datasources, dashboards, and alert rules are auto-provisioned."
    echo ""
    echo "  Telegram Notifications:"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        echo "    Bot Token:    configured"
        echo "    Chat ID:      ${TELEGRAM_CHAT_ID}"
    else
        echo "    Not configured - set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in config.env"
    fi
    echo ""
    echo "  Backup:"
    echo "    Schedule:   Nightly at 4:00 AM"
    echo "    Location:   /${CONTAINER_SSD_PATH}/monitoring/backups"
    echo "    Retention:  7 backups"
    echo "    Restore:    /opt/monitoring/restore.sh"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
