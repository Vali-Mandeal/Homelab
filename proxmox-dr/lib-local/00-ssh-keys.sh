#!/usr/bin/env bash
# ==============================================================================
# SSH Key Generation and Management
# ==============================================================================
# This module runs on your LOCAL workstation
# Handles SSH key generation and validation
# ==============================================================================

# ==============================================================================
# Constants
# ==============================================================================

readonly SSH_KEY_TYPE="ed25519"
readonly SSH_KEY_PATH="$HOME/.ssh/homelab_admin"
readonly SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_ssh_keys() {
    log_section "SSH Key Setup"

    ensure_main_key_exists
    configure_ssh_shortcuts
    deploy_key_to_proxmox

    log_info "✓ SSH key setup complete"
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

ensure_main_key_exists() {
    if check_ssh_key_exists; then
        log_info "Found existing SSH key: $SSH_KEY_PATH"
        validate_ssh_key_permissions "$SSH_KEY_PATH"
    else
        prompt_generate_main_key
    fi

    export SSH_PUBLIC_KEY_PATH="$SSH_PUB_KEY_PATH"
}

configure_ssh_shortcuts() {
    create_ssh_config
}

deploy_key_to_proxmox() {
    if test_ssh_key_authentication; then
        log_info "SSH key already deployed to Proxmox"
    else
        prompt_and_deploy_key
    fi

    # Also deploy the keypair TO Proxmox so it can SSH into VMs
    deploy_keypair_to_proxmox
}

prompt_and_deploy_key() {
    log_warn "SSH key not yet deployed to Proxmox"

    read -p "Deploy SSH key to Proxmox now? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        execute_key_deployment
    else
        log_warn "Skipping SSH key deployment"
        log_warn "You'll need to enter password for SSH connections"
        return 1
    fi
}

execute_key_deployment() {
    if ! deploy_ssh_key_to_proxmox; then
        return 1
    fi

    verify_key_deployment
}

verify_key_deployment() {
    if test_ssh_key_authentication; then
        return 0
    else
        log_error "SSH key deployed but authentication still failing"
        return 1
    fi
}

# ==============================================================================
# Key Validation
# ==============================================================================

check_ssh_key_exists() {
    [[ -f "$SSH_KEY_PATH" ]] && [[ -f "$SSH_PUB_KEY_PATH" ]]
}

validate_ssh_key_permissions() {
    local key_path="$1"
    local current_perms
    current_perms=$(stat -f "%OLp" "$key_path" 2>/dev/null || stat -c "%a" "$key_path" 2>/dev/null)

    if [[ "$current_perms" != "600" ]]; then
        log_warn "Fixing permissions on $key_path"
        chmod 600 "$key_path"
    fi
}

# ==============================================================================
# Key Generation
# ==============================================================================

generate_ssh_key() {
    local key_path="$1"
    local key_comment="$2"
    local use_passphrase="$3"

    log_info "Generating SSH key: $key_path"

    if [[ "$use_passphrase" == "true" ]]; then
        ssh-keygen -t "$SSH_KEY_TYPE" -C "$key_comment" -f "$key_path"
    else
        ssh-keygen -t "$SSH_KEY_TYPE" -C "$key_comment" -f "$key_path" -N ""
    fi

    if [[ $? -eq 0 ]]; then
        secure_generated_key "$key_path"
        log_info "SSH key generated successfully"
        return 0
    else
        log_error "Failed to generate SSH key"
        return 1
    fi
}

secure_generated_key() {
    local key_path="$1"
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
}

prompt_generate_main_key() {
    log_section "SSH Key Setup"

    log_warn "No SSH key found at: $SSH_KEY_PATH"
    log_info "This key is required for accessing Proxmox and VMs"
    echo ""

    if ! prompt_user_for_key_generation; then
        exit_with_manual_instructions
    fi
}

prompt_user_for_key_generation() {
    read -p "Generate SSH key now? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        generate_main_key_with_passphrase
        return $?
    else
        return 1
    fi
}

generate_main_key_with_passphrase() {
    log_info "You will be prompted for a passphrase (recommended for security)"
    log_info "Press Enter twice for no passphrase (not recommended)"
    echo ""

    if generate_ssh_key "$SSH_KEY_PATH" "homelab-admin@$(hostname)" "true"; then
        log_info "Main SSH key created: $SSH_KEY_PATH"
        return 0
    else
        return 1
    fi
}

exit_with_manual_instructions() {
    log_error "SSH key is required to continue"
    log_info "Please generate one manually:"
    log_info "  ssh-keygen -t ed25519 -f $SSH_KEY_PATH"
    exit 1
}

# ==============================================================================
# SSH Config Management
# ==============================================================================

create_ssh_config() {
    local ssh_config_file="$HOME/.ssh/config"

    if ssh_config_has_proxmox_entry "$ssh_config_file"; then
        log_info "SSH config already contains Proxmox entry"
        return 0
    fi

    log_info "Adding Proxmox to SSH config..."

    prepare_ssh_config_directory
    append_proxmox_config "$ssh_config_file"
    secure_ssh_config "$ssh_config_file"
    log_ssh_config_usage
}

ssh_config_has_proxmox_entry() {
    local ssh_config_file="$1"
    [[ -f "$ssh_config_file" ]] && grep -q "Host proxmox" "$ssh_config_file"
}

prepare_ssh_config_directory() {
    mkdir -p "$HOME/.ssh"
}

append_proxmox_config() {
    local ssh_config_file="$1"

    cat >> "$ssh_config_file" << EOF

# Proxmox Homelab Configuration (Auto-generated)
Host proxmox pve
    HostName ${PROXMOX_HOST}
    User ${SSH_USER}
    IdentityFile ${SSH_KEY_PATH}
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
}

secure_ssh_config() {
    local ssh_config_file="$1"
    chmod 600 "$ssh_config_file"
}

log_ssh_config_usage() {
    log_info "SSH config updated: $HOME/.ssh/config"
    log_info "You can now use: ssh proxmox"
}

# ==============================================================================
# Key Deployment
# ==============================================================================

deploy_ssh_key_to_proxmox() {
    log_section "Deploying SSH Key to Proxmox"

    log_info "Copying SSH public key to Proxmox host..."
    log_info "You will be prompted for the root password"
    echo ""

    try_ssh_copy_id || try_fallback_copy
}

try_ssh_copy_id() {
    if ! command -v ssh-copy-id &> /dev/null; then
        return 1
    fi

    if ssh-copy-id -i "$SSH_PUB_KEY_PATH" -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}" 2>/dev/null; then
        log_info "SSH key deployed successfully"
        return 0
    else
        return 1
    fi
}

try_fallback_copy() {
    log_info "Using fallback method..."

    if cat "$SSH_PUB_KEY_PATH" | ssh -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}" \
        "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"; then
        log_info "SSH key deployed successfully"
        return 0
    else
        log_deployment_failure_instructions
        return 1
    fi
}

log_deployment_failure_instructions() {
    log_error "Failed to deploy SSH key"
    log_info "You can manually copy it later:"
    log_info "  ssh-copy-id -i $SSH_PUB_KEY_PATH -p $SSH_PORT ${SSH_USER}@${PROXMOX_HOST}"
}

test_ssh_key_authentication() {
    log_info "Testing SSH key authentication..."

    if ssh -i "$SSH_KEY_PATH" -o "PasswordAuthentication=no" -o "BatchMode=yes" -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}" "echo 'SSH key auth works'" &>/dev/null; then
        log_info "✓ SSH key authentication successful"
        return 0
    else
        log_warn "SSH key authentication not working yet"
        return 1
    fi
}

# ==============================================================================
# Keypair Deployment to Proxmox (for VM access)
# ==============================================================================
# Proxmox needs the full keypair (private + public) so it can SSH into VMs
# that were provisioned with the corresponding public key via cloud-init.
# ==============================================================================

deploy_keypair_to_proxmox() {
    log_section "Deploying SSH Keypair to Proxmox"

    if check_keypair_on_proxmox; then
        log_info "SSH keypair already present on Proxmox"
        return 0
    fi

    log_info "Proxmox needs the SSH keypair to access VMs provisioned with cloud-init"
    copy_keypair_to_proxmox
}

check_keypair_on_proxmox() {
    ssh -i "$SSH_KEY_PATH" -o "BatchMode=yes" -p "$SSH_PORT" \
        "${SSH_USER}@${PROXMOX_HOST}" \
        "[[ -f /root/.ssh/homelab_admin ]] && [[ -f /root/.ssh/homelab_admin.pub ]]" &>/dev/null
}

copy_keypair_to_proxmox() {
    log_info "Copying SSH keypair to Proxmox at /root/.ssh/..."

    # Copy private key
    if ! scp -i "$SSH_KEY_PATH" -P "$SSH_PORT" \
        "$SSH_KEY_PATH" "${SSH_USER}@${PROXMOX_HOST}:/root/.ssh/homelab_admin"; then
        log_error "Failed to copy private key to Proxmox"
        return 1
    fi

    # Copy public key
    if ! scp -i "$SSH_KEY_PATH" -P "$SSH_PORT" \
        "$SSH_PUB_KEY_PATH" "${SSH_USER}@${PROXMOX_HOST}:/root/.ssh/homelab_admin.pub"; then
        log_error "Failed to copy public key to Proxmox"
        return 1
    fi

    # Set correct permissions
    ssh -i "$SSH_KEY_PATH" -o "BatchMode=yes" -p "$SSH_PORT" \
        "${SSH_USER}@${PROXMOX_HOST}" \
        "chmod 600 /root/.ssh/homelab_admin && chmod 644 /root/.ssh/homelab_admin.pub"

    log_info "✓ SSH keypair deployed to Proxmox"
}
