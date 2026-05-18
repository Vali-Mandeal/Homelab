#!/usr/bin/env bash
# ==============================================================================
# SSH Configuration
# ==============================================================================
# Setup SSH key-based authentication for root access
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_ssh_access() {
    log_section "Setting Up SSH Key-Based Authentication"

    if [[ -z "${SSH_PUBLIC_KEY_CONTENT:-}" ]]; then
        log_info "SSH key already configured by deploy script, skipping"
        return 0
    fi

    create_ssh_directory
    add_ssh_key_to_authorized_keys "$SSH_PUBLIC_KEY_CONTENT"

    log_info "SSH configuration complete"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

create_ssh_directory() {
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
}

add_ssh_key_to_authorized_keys() {
    local ssh_key_content="$1"

    if grep -q "$ssh_key_content" /root/.ssh/authorized_keys 2>/dev/null; then
        log_info "SSH key already present in authorized_keys"
        return 0
    fi

    echo "$ssh_key_content" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log_info "SSH key added to authorized_keys"
}
