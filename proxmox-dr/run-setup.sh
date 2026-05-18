#!/usr/bin/env bash
# ==============================================================================
# Proxmox Disaster Recovery Setup Script
# ==============================================================================
# Purpose: Complete DR setup on Proxmox host
# Target: Proxmox VE
# Usage: sudo ./run-setup.sh
# ==============================================================================
#
# This script runs ON the Proxmox host (copied there by deploy-proxmox.sh)
# and performs the complete DR setup.
#

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/proxmox-config.env"

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
    display_banner
    load_configuration
    perform_preflight_checks
    execute_proxmox_setup
    print_summary

    log_info "Proxmox DR setup completed successfully!"
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

load_configuration() {
    load_config
    validate_config
    display_configuration_summary
}

perform_preflight_checks() {
    log_section "Pre-Flight Checks"
    check_root_privileges
    validate_proxmox_environment
    check_required_commands
    log_info "Pre-flight checks passed"
}

execute_proxmox_setup() {
    configure_proxmox_repositories
    remove_subscription_notice
    disable_postfix_email
    upgrade_proxmox_packages
    configure_system_locale
    setup_powertop
    setup_glances
    setup_wake_on_lan
    setup_ssh_access
    configure_network_bridges
    setup_lxc_id_mapping
    setup_storage_infrastructure
    create_ubuntu_template
    create_golden_image_template
    setup_proxmox_api_users
}

setup_storage_infrastructure() {
    setup_storage_mounts
    setup_image_storage
}

# ==============================================================================
# Module Loading
# ==============================================================================

# Source all library modules in order
for lib_file in "$SCRIPT_DIR/lib/"*.sh; do
    if [[ -f "$lib_file" ]]; then
        source "$lib_file"
    fi
done

# ==============================================================================
# Display Functions
# ==============================================================================

display_banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║          Proxmox Disaster Recovery Setup                       ║"
    echo "║          Homelab Infrastructure                                ║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

display_configuration_summary() {
    log_info "Proxmox Host: $PROXMOX_HOSTNAME ($PROXMOX_HOST_IP)"
    echo ""
}

# ==============================================================================
# Configuration Management
# ==============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    log_info "Loading configuration..."
    source "$CONFIG_FILE"

    set_configuration_defaults
}

set_configuration_defaults() {
    PRIVATE_NETWORK_BRIDGE="${PRIVATE_NETWORK_BRIDGE:-$DEFAULT_PRIVATE_NETWORK_BRIDGE}"
    PUBLIC_NETWORK_BRIDGE="${PUBLIC_NETWORK_BRIDGE:-$DEFAULT_PUBLIC_NETWORK_BRIDGE}"
    DNS_SERVERS="${DNS_SERVERS:-$DEFAULT_DNS_SERVERS}"
}

# ==============================================================================
# Validation Functions
# ==============================================================================

check_root_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        log_info "Try: sudo ./run-setup.sh"
        exit 1
    fi
}

check_required_commands() {
    for cmd in wget ssh rsync; do
        if ! check_command "$cmd"; then
            exit 1
        fi
    done
}

# ==============================================================================
# Error Handling
# ==============================================================================

trap 'log_error "Script failed at line $LINENO"' ERR

# ==============================================================================
# Script Entry Point
# ==============================================================================

main "$@"
