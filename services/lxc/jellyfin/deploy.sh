#!/usr/bin/env bash
# ==============================================================================
# Jellyfin - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC, installs Jellyfin natively, configures
# iGPU passthrough, UID mapping, bind mounts, and hybrid storage.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/lxc-service.sh"

if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Jellyfin"

    verify_host_mounts
    create_jellyfin_container
    install_jellyfin
    configure_jellyfin_user
    configure_lxc_journal
    deploy_scripts
    run_bootstrap
    print_jellyfin_summary
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

verify_host_mounts() {
    log_section "Verifying Host Mounts"

    if ! mountpoint -q "$PROXMOX_SSD_PATH" 2>/dev/null; then
        log_error "SMB mount not found at ${PROXMOX_SSD_PATH}. Run proxmox-dr first!"
        exit 1
    fi
    log_info "SMB mount OK: ${PROXMOX_SSD_PATH}"

    if ! mountpoint -q "$PROXMOX_MEDIA_PATH" 2>/dev/null; then
        log_warn "Media mount not found at ${PROXMOX_MEDIA_PATH} - Jellyfin will have no media"
    else
        log_info "Media mount OK: ${PROXMOX_MEDIA_PATH}"
    fi
}

# ==============================================================================
# Container Creation with Jellyfin-specific config
# ==============================================================================

create_jellyfin_container() {
    local storage="${CT_STORAGE:-local-lvm}"
    local template
    template=$(select_lxc_template)

    log_section "Creating LXC Container: ${CT_NAME} (${CT_ID})"

    destroy_existing_container
    create_base_container "$template" "$storage"

    # Configure BEFORE first start
    setup_uid_mapping

    if [[ "${IGPU_PASSTHROUGH:-false}" == "true" ]]; then
        setup_gpu_passthrough
    fi

    # Bind mounts (lxc.mount.entry - not mp0/mp1)
    setup_bind_mount "$PROXMOX_MEDIA_PATH" "$CONTAINER_MEDIA_PATH"
    setup_bind_mount "$PROXMOX_SSD_PATH" "$CONTAINER_SSD_PATH"

    # Start after all config is done
    start_and_wait
    set_static_ip

    log_info "Container ${CT_NAME} (${CT_ID}) ready at ${CT_IP}"
}

# ==============================================================================
# Jellyfin Installation
# ==============================================================================

install_jellyfin() {
    log_section "Installing Jellyfin"

    install_packages curl apt-transport-https ca-certificates gnupg lsb-release

    # Detect distro and add Jellyfin repo
    local distro
    distro=$(pct exec "$CT_ID" -- bash -c 'source /etc/os-release && echo $ID')
    log_info "Detected distro: ${distro}"

    local repo_url="https://repo.jellyfin.org/${distro}"

    pct exec "$CT_ID" -- bash -c "
        curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/jellyfin.gpg
        echo \"deb [arch=\$(dpkg --print-architecture)] ${repo_url} \$(lsb_release -cs) main\" > /etc/apt/sources.list.d/jellyfin.list
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y jellyfin
    "

    log_info "Jellyfin installed"

    # Fix config permissions immediately
    pct exec "$CT_ID" -- bash -c "
        chown -R ${NAS_SMB_UID}:${NAS_SMB_UID} /etc/jellyfin
        find /etc/jellyfin -type f -exec chmod 664 {} \;
        find /etc/jellyfin -type d -exec chmod 755 {} \;
    "
}

# ==============================================================================
# User Configuration
# ==============================================================================

configure_jellyfin_user() {
    log_section "Configuring Jellyfin User (UID ${NAS_SMB_UID})"

    pct exec "$CT_ID" -- bash -c "
        systemctl stop jellyfin
        usermod -u ${NAS_SMB_UID} jellyfin
        groupmod -g ${NAS_SMB_UID} jellyfin
        chown -R ${NAS_SMB_UID}:${NAS_SMB_UID} /var/lib/jellyfin /etc/jellyfin /var/cache/jellyfin
        mkdir -p /var/log/jellyfin
        chown -R ${NAS_SMB_UID}:${NAS_SMB_UID} /var/log/jellyfin
    "

    # Setup GPU access for jellyfin user
    if [[ "${IGPU_PASSTHROUGH:-false}" == "true" ]]; then
        local render_gid
        render_gid=$(getent group render | cut -d: -f3)
        local container_render_gid=$((render_gid + 100000))

        pct exec "$CT_ID" -- bash -c "
            groupadd --gid ${container_render_gid} render 2>/dev/null || true
            usermod -aG render jellyfin
            apt-get install -y -qq intel-opencl-icd > /dev/null 2>&1 || true
        "
        log_info "GPU access configured for jellyfin user"
    fi

    log_info "Jellyfin user configured (UID ${NAS_SMB_UID})"
}

# ==============================================================================
# LXC Journal Configuration
# ==============================================================================

configure_lxc_journal() {
    log_section "Disabling rsyslogd (suppress AppArmor spam)"

    # rsyslogd in an unprivileged LXC tries to use /dev/log → /run/systemd/journal/dev-log
    # via the imuxsock module, which AppArmor denies on the host, spamming audit logs.
    # Jellyfin logs go to /var/log/jellyfin/ and are collected by Alloy file-based collection.
    pct exec "$CT_ID" -- bash -c "
        systemctl stop rsyslog 2>/dev/null || true
        systemctl disable rsyslog 2>/dev/null || true
        systemctl stop syslog.socket 2>/dev/null || true
    "

    log_info "rsyslogd disabled (logs handled by Alloy)"
}

# ==============================================================================
# Deploy Scripts
# ==============================================================================

deploy_scripts() {
    log_info "Deploying bootstrap and backup scripts..."

    for script in bootstrap.sh nightly-backup.sh restore.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            push_file "${SCRIPT_DIR}/${script}" "/root/${script}"
            pct exec "$CT_ID" -- chmod +x "/root/${script}"
        fi
    done

    # Runtime env for the in-container scripts (so they don't hardcode paths)
    pct exec "$CT_ID" -- bash -c "cat > /etc/jellyfin-runtime.env" <<EOF
BACKUP_ROOT=${JELLYFIN_BACKUP_ROOT}
MEDIA_ROOT=/${CONTAINER_MEDIA_PATH}
SMB_MOUNT_ROOT=/${CONTAINER_SSD_PATH}
JELLYFIN_UID=${NAS_SMB_UID}
JELLYFIN_GID=${NAS_SMB_UID}
EOF

    log_info "Scripts deployed"
}

# ==============================================================================
# Bootstrap
# ==============================================================================

run_bootstrap() {
    log_section "Running Bootstrap"

    if [[ ! -f "${SCRIPT_DIR}/bootstrap.sh" ]]; then
        log_warn "No bootstrap.sh found - skipping"
        pct exec "$CT_ID" -- systemctl start jellyfin
        return 0
    fi

    pct exec "$CT_ID" -- /root/bootstrap.sh
}

# ==============================================================================
# Summary
# ==============================================================================

print_jellyfin_summary() {
    log_section "Jellyfin Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo "  Web UI:     http://${CT_IP}:8096"
    echo "  Traefik:    https://jellyfin.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  Storage:"
    echo "    Live DB:  /var/lib/jellyfin (local)"
    echo "    Media:    /${CONTAINER_MEDIA_PATH} (NFS)"
    echo "    Backups:  ${JELLYFIN_BACKUP_ROOT}/backups (SMB)"
    echo ""
    echo "  Backup:     Nightly at 3 AM (7-day retention)"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
