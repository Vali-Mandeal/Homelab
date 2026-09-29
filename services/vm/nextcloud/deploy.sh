#!/usr/bin/env bash
# ==============================================================================
# Nextcloud - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates a VM from golden image, installs Docker, configures
# SMB mounts, deploys Nextcloud with PostgreSQL + Redis.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/vm-service.sh"
source "${DEPLOY_ROOT}/lib/heal-nas-mounts.sh"

if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Nextcloud"

    check_ssh_key
    create_vm
    setup_base_packages
    setup_storage_mounts
    setup_mount_resilience
    install_docker_in_vm
    install_portainer_agent
    deploy_nextcloud_files
    run_bootstrap
    print_nextcloud_summary
}

# ==============================================================================
# Pre-flight
# ==============================================================================

check_ssh_key() {
    if [[ ! -f "/root/.ssh/homelab_admin" ]]; then
        log_error "SSH private key not found at /root/.ssh/homelab_admin"
        log_error "Ensure the key is deployed to Proxmox (see proxmox-dr setup)"
        exit 1
    fi
    if [[ ! -f "/root/.ssh/homelab_admin.pub" ]]; then
        log_error "SSH public key not found at /root/.ssh/homelab_admin.pub"
        exit 1
    fi
}

# ==============================================================================
# Base Packages
# ==============================================================================

setup_base_packages() {
    log_section "Installing Base Packages"
    install_packages_vm curl wget jq sudo
}

# ==============================================================================
# Storage Mounts
# ==============================================================================

setup_storage_mounts() {
    log_section "Configuring Storage Mounts"

    # User data: personal files (nextcloud.server credentials)
    setup_smb_mount_vm "$SMB_HOST" "$SMB_SHARE_1" "$SMB_MOUNT_1" \
        "$SMB_UID" "$SMB_GID" "$SMB_PRIVATE_USERNAME" "$SMB_PRIVATE_PASSWORD"

    # User data: shared files (nextcloud.server credentials)
    setup_smb_mount_vm "$SMB_HOST" "$SMB_SHARE_2" "$SMB_MOUNT_2" \
        "$SMB_UID" "$SMB_GID" "$SMB_PRIVATE_USERNAME" "$SMB_PRIVATE_PASSWORD"

    # Backups: server data SSD (proxmox.server from homelab.env)
    setup_smb_mount_vm "$SMB_HOST" "$SMB_SHARE_BACKUP" "$SMB_MOUNT_BACKUP" \
        "$SMB_UID" "$SMB_GID" "$SMB_USERNAME" "$SMB_PASSWORD"

    log_info "Storage mounts configured"
}

# ==============================================================================
# Mount Resilience (heal-nas-mounts timer + docker.service drop-in)
# ==============================================================================

setup_mount_resilience() {
    log_section "Installing NAS Mount Resilience"

    # Pass every SMB mount path so docker.service waits for all of them and
    # the heal timer can recover whichever fails at boot.
    setup_vm_nas_mount_resilience \
        "$SMB_MOUNT_1" "$SMB_MOUNT_2" "$SMB_MOUNT_BACKUP"
}

# ==============================================================================
# Deploy Nextcloud Files
# ==============================================================================

deploy_nextcloud_files() {
    log_section "Deploying Nextcloud Files"

    ssh_vm "mkdir -p /opt/nextcloud"

    for file in docker-compose.yml .env bootstrap.sh nightly-backup.sh nightly-security-updates.sh restore.sh onlyoffice-entrypoint.sh; do
        if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
            scp_vm "${SCRIPT_DIR}/${file}" "root@${VM_IP}:/opt/nextcloud/${file}"
        fi
    done

    # Write infra IPs from homelab.env into a separate file that bootstrap.sh sources.
    # Kept out of the committed .env so we don't bake concrete IPs into the repo.
    : "${TRAEFIK_CT_IP:?TRAEFIK_CT_IP must be set in homelab.env}"
    ssh_vm "cat > /opt/nextcloud/.env.infra" <<EOF
TRAEFIK_CT_IP=${TRAEFIK_CT_IP}
EOF

    ssh_vm "chmod +x /opt/nextcloud/bootstrap.sh /opt/nextcloud/nightly-backup.sh /opt/nextcloud/nightly-security-updates.sh /opt/nextcloud/restore.sh /opt/nextcloud/onlyoffice-entrypoint.sh"

    log_info "Nextcloud files deployed to /opt/nextcloud/"
}

# ==============================================================================
# Bootstrap
# ==============================================================================

run_bootstrap() {
    log_section "Running Bootstrap"

    ssh_vm "cd /opt/nextcloud && ./bootstrap.sh"
}

# ==============================================================================
# Summary
# ==============================================================================

print_nextcloud_summary() {
    log_section "Nextcloud Deployed Successfully"

    echo "  VM:           ${VM_NAME} (VM ${VM_ID})"
    echo "  IP:           ${VM_IP}"
    echo ""
    echo "  Services:"
    echo "    Nextcloud:    http://${VM_IP}:8080"
    echo "    Local:        https://nextcloud.${TRAEFIK_DOMAIN}"
    echo "    Public:       https://nextcloud.${PUBLIC_DOMAIN}"
    echo ""
    echo "  Storage:"
    echo "    Personal:   ${SMB_MOUNT_1} (SMB)"
    echo "    Shared:     ${SMB_MOUNT_2} (SMB)"
    echo "    Backups:    ${SMB_MOUNT_BACKUP}/nextcloud (SMB)"
    echo "    Local DBs:  /opt/nextcloud/databases (local)"
    echo ""
    echo "  Backup:       Nightly at 3 AM (7-day retention)"
    echo ""
    echo "  Post-deploy:"
    echo "    1. Add Cloudflare tunnel route: nextcloud.${PUBLIC_DOMAIN} → http://${VM_IP}:8080"
    echo "    2. Log in and enable Two-Factor TOTP in Settings → Security"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
