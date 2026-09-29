#!/usr/bin/env bash
# ==============================================================================
# Nextcloud - Rollback Script
# ==============================================================================
# Runs ON Proxmox. SSHs into the Nextcloud VM to revert to the most recent
# pre-upgrade state.
#
# What it does:
#   1. Verifies :rollback image tags exist on the VM (set by update.sh before
#      its docker compose pull). If missing, bails - there's nothing to roll
#      back to.
#   2. Stops containers.
#   3. Points docker-compose.yml at nextcloud:rollback and
#      onlyoffice/documentserver:rollback (local tags, not pulled).
#   4. Restores the DB from the most recent backup (restore.sh on the VM).
#   5. Brings the stack back up and waits for healthy.
#
# After running this, the compose file references :rollback tags. When you
# are ready to try updating again, edit the compose file back to :latest
# (or just re-run the deploy) so the next update.sh advances forward again.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

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
    display_banner "Rolling back Nextcloud"

    verify_vm_accessible
    verify_rollback_available
    confirm_rollback
    perform_rollback
    print_rollback_summary
}

# ==============================================================================
# Pre-flight
# ==============================================================================

verify_vm_accessible() {
    log_section "Verifying VM Access"

    if ! ssh_vm "echo connected" &>/dev/null; then
        log_error "Cannot connect to Nextcloud VM at ${VM_IP}"
        exit 1
    fi
    log_info "VM ${VM_NAME} (${VM_IP}) is accessible"
}

verify_rollback_available() {
    log_section "Checking Rollback Availability"

    if ! ssh_vm "docker image inspect nextcloud:rollback >/dev/null 2>&1"; then
        log_error "No nextcloud:rollback tag found on VM."
        log_error "Rollback requires a previous successful update.sh run to set"
        log_error "the tag. There is nothing to roll back to."
        exit 1
    fi
    log_info "nextcloud:rollback image is present"

    if ssh_vm "docker image inspect onlyoffice/documentserver:rollback >/dev/null 2>&1"; then
        log_info "onlyoffice/documentserver:rollback image is present"
    else
        log_warn "No onlyoffice/documentserver:rollback tag - will leave OnlyOffice on current :latest"
    fi
}

confirm_rollback() {
    log_section "Confirmation"

    # Report what we're rolling back FROM and TO so the user has full visibility.
    local current_version
    current_version=$(ssh_vm "docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null" \
        | grep -o '"versionstring":"[^"]*"' | cut -d'"' -f4) || true

    local rollback_image_id
    rollback_image_id=$(ssh_vm "docker image inspect --format='{{.Id}}' nextcloud:rollback 2>/dev/null" \
        | head -c 19)

    echo "  Currently running:  Nextcloud ${current_version:-?}"
    echo "  Will roll back to:  image ${rollback_image_id} (the :rollback tag)"
    echo "  Database:           will be RESTORED from the most recent backup"
    echo ""
    log_warn "This restores the DB from backup. Any data written since the"
    log_warn "last backup snapshot will be LOST."
    echo ""

    local answer
    read -r -p "  Proceed with rollback? [y/N] " answer
    if [[ ! "$answer" =~ ^[yY]$ ]]; then
        log_info "Aborted. Nothing changed."
        exit 0
    fi
}

# ==============================================================================
# Rollback Steps
# ==============================================================================

perform_rollback() {
    log_section "Performing Rollback"

    log_info "Stopping containers..."
    ssh_vm "cd /opt/nextcloud && docker compose down" || true

    log_info "Pointing compose at :rollback tags..."
    ssh_vm "sed -i 's|image: nextcloud:.*|image: nextcloud:rollback|' /opt/nextcloud/docker-compose.yml"
    # Only swap the onlyoffice tag if the rollback image exists
    if ssh_vm "docker image inspect onlyoffice/documentserver:rollback >/dev/null 2>&1"; then
        ssh_vm "sed -i 's|image: onlyoffice/documentserver:.*|image: onlyoffice/documentserver:rollback|' /opt/nextcloud/docker-compose.yml"
    fi

    log_info "Restoring database from most recent backup..."
    if ! ssh_vm "cd /opt/nextcloud && bash restore.sh"; then
        log_error "Restore failed. Manual intervention required."
        log_error "SSH to VM and inspect: /opt/nextcloud/restore.sh"
        exit 1
    fi

    log_info "Starting services with rollback images..."
    ssh_vm "cd /opt/nextcloud && docker compose up -d"

    log_info "Waiting for Nextcloud to become healthy (up to 300s)..."
    local timeout=300
    local elapsed=0
    local healthy=false

    while [[ $elapsed -lt $timeout ]]; do
        if ssh_vm "docker exec nextcloud curl -fsS http://localhost/status.php" &>/dev/null; then
            healthy=true
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        log_info "  Waiting... (${elapsed}s/${timeout}s)"
    done

    if [[ "$healthy" != "true" ]]; then
        log_error "Nextcloud did not become healthy within ${timeout}s after rollback"
        log_error "Check container logs: ssh root@${VM_IP} 'docker logs nextcloud'"
        exit 1
    fi

    log_info "Nextcloud healthy on rollback image"

    # Disable maintenance mode if it was left on by the failed upgrade
    ssh_vm "docker exec -u www-data nextcloud php occ maintenance:mode --off" 2>/dev/null || true
}

# ==============================================================================
# Summary
# ==============================================================================

print_rollback_summary() {
    log_section "Rollback Complete"

    local new_version
    new_version=$(ssh_vm "docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null" \
        | grep -o '"versionstring":"[^"]*"' | cut -d'"' -f4) || true

    echo "  Now running:        Nextcloud ${new_version:-?}"
    echo "  Compose file:       /opt/nextcloud/docker-compose.yml (points at :rollback)"
    echo ""
    log_warn "When ready to upgrade again, edit /opt/nextcloud/docker-compose.yml"
    log_warn "(or re-deploy) to point back at :latest before running update.sh."
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
