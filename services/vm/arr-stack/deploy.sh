#!/usr/bin/env bash
# ==============================================================================
# ARR Stack - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates a VM from golden image, installs Docker, configures
# NFS/SMB mounts, deploys ARR stack with hybrid storage (local DBs + SMB backups).
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
    display_banner "Deploying ARR Stack"

    check_ssh_key
    create_vm
    setup_base_packages
    setup_storage_mounts
    setup_mount_resilience
    install_docker_in_vm
    install_portainer_agent
    deploy_arr_files
    run_bootstrap
    print_arr_summary
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

    # Ensure /dev/net/tun exists for Gluetun VPN container
    ssh_vm "mkdir -p /dev/net && [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun"
}

# ==============================================================================
# Storage Mounts
# ==============================================================================

setup_storage_mounts() {
    log_section "Configuring Storage Mounts"

    setup_nfs_mount_vm "$NFS_HOST" "$NFS_SHARE" "$NFS_MOUNT"
    setup_smb_mount_vm "$SMB_HOST" "$SMB_SHARE" "$SMB_MOUNT" \
        "$SMB_UID" "$SMB_GID" "$SMB_USERNAME" "$SMB_PASSWORD"

    log_info "Storage mounts configured"
}

# ==============================================================================
# Mount Resilience (heal-nas-mounts timer + docker.service drop-in)
# ==============================================================================

setup_mount_resilience() {
    log_section "Installing NAS Mount Resilience"

    setup_vm_nas_mount_resilience "$NFS_MOUNT" "$SMB_MOUNT"
}

# ==============================================================================
# Deploy ARR Files
# ==============================================================================

deploy_arr_files() {
    log_section "Deploying ARR Stack Files"

    ssh_vm "mkdir -p /opt/arr"

    for file in docker-compose.yml .env bootstrap.sh nightly-backup.sh restore.sh; do
        if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
            scp_vm "${SCRIPT_DIR}/${file}" "root@${VM_IP}:/opt/arr/${file}"
        fi
    done

    ssh_vm "chmod +x /opt/arr/bootstrap.sh /opt/arr/nightly-backup.sh /opt/arr/restore.sh"

    log_info "ARR stack files deployed to /opt/arr/"
}

# ==============================================================================
# Bootstrap
# ==============================================================================

run_bootstrap() {
    log_section "Running Bootstrap"

    ssh_vm "cd /opt/arr && ./bootstrap.sh"
}

# ==============================================================================
# Summary
# ==============================================================================

print_arr_summary() {
    log_section "ARR Stack Deployed Successfully"

    echo "  VM:           ${VM_NAME} (VM ${VM_ID})"
    echo "  IP:           ${VM_IP}"
    echo ""
    echo "  Services:"
    echo "    Radarr:       http://${VM_IP}:7878   (https://radarr.${TRAEFIK_DOMAIN})"
    echo "    Sonarr:       http://${VM_IP}:8989   (https://sonarr.${TRAEFIK_DOMAIN})"
    echo "    Prowlarr:     http://${VM_IP}:9696   (https://prowlarr.${TRAEFIK_DOMAIN})"
    echo "    qBittorrent:  http://${VM_IP}:8080   (https://qbittorrent.${TRAEFIK_DOMAIN})"
    echo "    Jellyseerr:   http://${VM_IP}:5055   (https://jellyseerr.${TRAEFIK_DOMAIN})"
    echo ""
    echo "  Storage:"
    echo "    Live DBs:   /opt/arr/databases (local)"
    echo "    Media:      ${NFS_MOUNT} (NFS)"
    echo "    Backups:    ${SMB_MOUNT}/arr (SMB)"
    echo ""
    echo "  Backup:       Nightly at 2 AM (7-day retention)"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
