#!/usr/bin/env bash
# ==============================================================================
# Nextcloud - Update Script
# ==============================================================================
# Runs ON Proxmox. SSHs into the Nextcloud VM to:
#   1. Apply OS security patches (apt upgrade)
#   2. Backup before upgrading (safety net)
#   3. Pull new Docker images and restart
#   4. Rollback on failure (restore backup + revert image tag)
#
# The Nextcloud Docker entrypoint handles DB migrations automatically when
# it detects a version mismatch between the image and installed data.
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
    display_banner "Updating Nextcloud"

    verify_vm_accessible
    update_host_os
    run_pre_upgrade_backup
    perform_upgrade
    print_update_summary
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

    if ! ssh_vm "cd /opt/nextcloud && bash nightly-backup.sh"; then
        log_error "Backup failed - aborting update (unsafe to proceed without backup)"
        exit 1
    fi

    log_info "Pre-upgrade backup completed"
}

# ==============================================================================
# Upgrade
# ==============================================================================

perform_upgrade() {
    log_section "Performing Upgrade"

    # Get current running version for rollback
    local current_version
    current_version=$(ssh_vm "docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null" | \
        grep -o '"versionstring":"[^"]*"' | cut -d'"' -f4) || true

    # Save current image tag for rollback (before overwriting compose file)
    local old_image_line
    old_image_line=$(ssh_vm "grep 'image: nextcloud:' /opt/nextcloud/docker-compose.yml")
    log_info "Current version: ${current_version:-unknown}"
    log_info "Current image: ${old_image_line}"

    # Push updated docker-compose.yml to VM (may have new image tag)
    log_info "Syncing docker-compose.yml to VM..."
    scp_vm "${SCRIPT_DIR}/docker-compose.yml" "root@${VM_IP}:/opt/nextcloud/docker-compose.yml"

    # Enable maintenance mode
    log_info "Enabling maintenance mode..."
    ssh_vm "docker exec -u www-data nextcloud php occ maintenance:mode --on" || true

    # Pull new images
    log_info "Pulling new Docker images..."
    ssh_vm "cd /opt/nextcloud && docker compose pull"

    # Restart with new images (entrypoint handles upgrade + DB migration)
    log_info "Restarting services..."
    ssh_vm "cd /opt/nextcloud && docker compose up -d"

    # Wait for healthy
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
        log_error "Nextcloud did not become healthy within ${timeout}s"
        rollback "$old_image_line"
        return
    fi

    log_info "Nextcloud is healthy"

    # Post-upgrade maintenance
    post_upgrade_maintenance

    # Disable maintenance mode
    log_info "Disabling maintenance mode..."
    ssh_vm "docker exec -u www-data nextcloud php occ maintenance:mode --off" || true

    # Clean up old images
    log_info "Cleaning up old Docker images..."
    ssh_vm "docker image prune -f" 2>/dev/null || true

    # Report new version
    local new_version
    new_version=$(ssh_vm "docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null" | \
        grep -o '"versionstring":"[^"]*"' | cut -d'"' -f4) || true
    log_info "Upgrade successful: ${new_version:-unknown}"
}

# ==============================================================================
# Post-Upgrade Maintenance
# ==============================================================================

post_upgrade_maintenance() {
    log_info "Running post-upgrade maintenance..."

    ssh_vm "docker exec -u www-data nextcloud php occ db:add-missing-indices" 2>/dev/null || true
    ssh_vm "docker exec -u www-data nextcloud php occ db:add-missing-columns" 2>/dev/null || true
    ssh_vm "docker exec -u www-data nextcloud php occ db:add-missing-primary-keys" 2>/dev/null || true
    ssh_vm "docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive" 2>/dev/null || true

    # Update all installed Nextcloud apps (OnlyOffice connector, Calendar, etc.)
    ssh_vm "docker exec -u www-data nextcloud php occ app:update --all" 2>/dev/null || true

    log_info "Post-upgrade maintenance complete"
}

# ==============================================================================
# Rollback
# ==============================================================================

rollback() {
    local old_image_line="$1"

    log_section "ROLLING BACK"
    log_warn "Upgrade failed - reverting to previous state"

    # Stop everything
    log_info "Stopping containers..."
    ssh_vm "cd /opt/nextcloud && docker compose down" || true

    # Revert docker-compose.yml to old image tag
    local old_tag
    old_tag=$(echo "$old_image_line" | sed 's/.*image: //')
    log_info "Reverting image to: ${old_tag}"
    ssh_vm "sed -i 's|image: nextcloud:.*|image: ${old_tag}|' /opt/nextcloud/docker-compose.yml"

    # Restore from the pre-upgrade backup
    log_info "Restoring database from pre-upgrade backup..."
    ssh_vm "cd /opt/nextcloud && bash restore.sh" || {
        log_error "Restore also failed! Manual intervention required."
        log_error "SSH into VM and check /opt/nextcloud/restore.sh"
        exit 1
    }

    # Start with old image
    log_info "Starting services with previous version..."
    ssh_vm "cd /opt/nextcloud && docker compose up -d"

    # Wait for healthy
    log_info "Waiting for rollback to complete..."
    local timeout=120
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ssh_vm "docker exec nextcloud curl -fsS http://localhost/status.php" &>/dev/null; then
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    if [[ $elapsed -ge $timeout ]]; then
        log_error "Rollback did not result in a healthy service. Manual intervention required."
        exit 1
    fi

    log_warn "Rollback complete - running previous version"
    log_warn "Check the Nextcloud logs for details on what went wrong"
    exit 1
}

# ==============================================================================
# Summary
# ==============================================================================

print_update_summary() {
    log_section "Nextcloud Update Complete"

    echo "  VM:         ${VM_NAME} (${VM_IP})"
    echo "  Status:     Healthy"
    echo "  URL:        https://nextcloud.${PUBLIC_DOMAIN}"
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
