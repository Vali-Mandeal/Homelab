#!/usr/bin/env bash
# ==============================================================================
# ARR Stack - Update Script
# ==============================================================================
# Runs ON Proxmox. SSHs into the ARR Stack VM to:
#   1. Apply OS security patches (apt upgrade)
#   2. Backup before upgrading (safety net)
#   3. Pull new Docker images and restart
#   4. Clean up old images
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/vm-service.sh"

if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Updating ARR Stack"

    verify_vm_accessible
    update_host_os
    run_pre_upgrade_backup
    pull_and_restart
    cleanup_images

    log_section "ARR Stack Update Complete"
    echo "  VM:         ${VM_NAME} (${VM_IP})"
    echo "  Status:     Updated"
    echo ""
}

# ==============================================================================
# Pre-flight
# ==============================================================================

verify_vm_accessible() {
    log_section "Verifying VM Access"

    if ! ssh_vm "echo connected" &>/dev/null; then
        log_error "Cannot connect to ARR Stack VM at ${VM_IP}"
        exit 1
    fi
    log_info "VM ${VM_NAME} (${VM_IP}) is accessible"
}

# ==============================================================================
# OS Security Patches
# ==============================================================================

update_host_os() {
    log_section "Applying OS Security Patches"

    ssh_vm "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"

    log_info "OS packages updated"
}

# ==============================================================================
# Pre-Upgrade Backup
# ==============================================================================

run_pre_upgrade_backup() {
    log_section "Running Pre-Upgrade Backup"

    log_info "Triggering nightly backup as safety net..."

    if ! ssh_vm "cd /opt/arr && bash nightly-backup.sh"; then
        log_error "Backup failed - aborting update (unsafe to proceed without backup)"
        exit 1
    fi

    log_info "Pre-upgrade backup completed"
}

# ==============================================================================
# Pull and Restart
# ==============================================================================

pull_and_restart() {
    log_section "Updating Docker Images"

    ssh_vm "cd /opt/arr && docker compose pull"
    ssh_vm "cd /opt/arr && docker compose up -d"

    log_info "Services restarted with new images"
}

# ==============================================================================
# Cleanup
# ==============================================================================

cleanup_images() {
    log_info "Cleaning up old Docker images..."
    ssh_vm "docker image prune -f" 2>/dev/null || true
}

main "$@"
