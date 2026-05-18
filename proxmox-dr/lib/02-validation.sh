#!/usr/bin/env bash
#
# Configuration Validation Functions
# Validates config, checks requirements
#

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found. Please install it first."
        return 1
    fi
    return 0
}

validate_config() {
    log_section "Validating Configuration"

    local required_vars=(
        "PROXMOX_HOST_IP"
        "PROXMOX_HOSTNAME"
        "GATEWAY_IP"
        "DNS_SERVERS"
        "PRIVATE_NETWORK_CIDR"
        "PUBLIC_NETWORK_CIDR"
        "PUBLIC_VLAN_TAG"
        "NAS_PRIVATE_IP"
        "NAS_PUBLIC_IP"
        "NFS_PUBLIC_MEDIA_MOUNT"
        "SMB_PRIVATE_MOUNT"
        "SMB_PUBLIC_MOUNT"
        "SMB_USERNAME"
        "SMB_PASSWORD"
        "SSH_PUBLIC_KEY_PATH"
    )

    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables:"
        for var in "${missing_vars[@]}"; do
            log_error "  - $var"
        done
        return 1
    fi

    log_info "Configuration validated successfully"
    return 0
}

validate_proxmox_environment() {
    log_info "Validating Proxmox environment..."

    # Check if running on Proxmox
    if [[ ! -f "$PROXMOX_VERSION_FILE" ]]; then
        log_warn "This doesn't appear to be a Proxmox VE system"
        return 1
    fi

    # Check required Proxmox commands
    local proxmox_commands=("qm" "pvesh" "pvesm")
    for cmd in "${proxmox_commands[@]}"; do
        if ! check_command "$cmd"; then
            log_error "Proxmox command not found: $cmd"
            return 1
        fi
    done

    log_info "Proxmox environment validated"
    return 0
}
