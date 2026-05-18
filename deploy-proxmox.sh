#!/usr/bin/env bash
# ==============================================================================
# Proxmox DR Deployment Orchestrator
# ==============================================================================
# This script runs on your Mac/workstation and handles:
# - Reading configuration
# - Testing SSH connectivity
# - Copying DR scripts to Proxmox
# - Executing remote setup
# - Cleaning up
#
# Usage: ./deploy-proxmox.sh
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Constants
# ==============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROXMOX_DR_DIR="${SCRIPT_DIR}/proxmox-dr"
readonly CONFIG_FILE="${SCRIPT_DIR}/configs/proxmox-dr.env"
readonly REMOTE_DIR_PREFIX="/tmp/proxmox-dr"
readonly LIB_LOCAL_DIR="${PROXMOX_DR_DIR}/lib-local"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ==============================================================================
# Logging
# ==============================================================================

log_info() {
    echo -e "${GREEN}[DEPLOY]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[DEPLOY]${NC} $1"
}

log_error() {
    echo -e "${RED}[DEPLOY]${NC} $1"
}

log_section() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
    echo ""
}

# ==============================================================================
# Error Handling
# ==============================================================================

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Deployment failed with exit code: $exit_code"
        attempt_cleanup
    fi
}

attempt_cleanup() {
    if [[ -n "${REMOTE_DIR:-}" ]] && [[ -n "${SSH_TARGET:-}" ]]; then
        log_info "Cleaning up remote directory: $REMOTE_DIR"
        local ssh_key_opt
        ssh_key_opt=$(get_ssh_key_option)
        ssh $ssh_key_opt -o ConnectTimeout=5 "$SSH_TARGET" "rm -rf '$REMOTE_DIR'" 2>/dev/null || true
    fi
}

trap cleanup_on_error EXIT

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
    log_section "Proxmox DR Deployment Orchestrator"

    initialize_deployment
    perform_deployment
    finalize_deployment
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

initialize_deployment() {
    load_configuration
    load_local_libraries
    setup_ssh_keys
    test_ssh_connection
}

perform_deployment() {
    copy_files_to_proxmox
    execute_remote_setup || {
        exit 1
    }
}

finalize_deployment() {
    cleanup_remote_files
    print_summary
    exit 0
}

# ==============================================================================
# Configuration Management
# ==============================================================================

load_configuration() {
    log_section "Loading Configuration"

    validate_config_file_exists
    source_config_file
    validate_required_variables
    set_default_values
    log_configuration_summary
}

validate_config_file_exists() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_config_file_not_found
        exit 1
    fi
}

log_config_file_not_found() {
    log_error "Configuration file not found: $CONFIG_FILE"
    log_info "Create it by copying the example:"
    log_info "  cp ${SCRIPT_DIR}/configs/proxmox-dr.env.example ${SCRIPT_DIR}/configs/proxmox-dr.env"
    log_info "  nano ${SCRIPT_DIR}/configs/proxmox-dr.env"
}

source_config_file() {
    log_info "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
}

validate_required_variables() {
    local required_vars=(
        "PROXMOX_HOST"
        "SSH_USER"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_missing_variables "${missing_vars[@]}"
        exit 1
    fi
}

log_missing_variables() {
    log_error "Missing required configuration variables:"
    for var in "$@"; do
        log_error "  - $var"
    done
}

set_default_values() {
    SSH_PORT="${SSH_PORT:-22}"
    SSH_TARGET="${SSH_USER}@${PROXMOX_HOST}"
}

log_configuration_summary() {
    log_info "Proxmox Host: ${PROXMOX_HOST}"
    log_info "SSH User: ${SSH_USER}"
    log_info "SSH Port: ${SSH_PORT}"
}

# ==============================================================================
# Library Loading
# ==============================================================================

load_local_libraries() {
    if [[ ! -d "$LIB_LOCAL_DIR" ]]; then
        return 0
    fi

    for lib_file in "$LIB_LOCAL_DIR"/*.sh; do
        if [[ -f "$lib_file" ]]; then
            # shellcheck disable=SC1090
            source "$lib_file"
        fi
    done
}

# ==============================================================================
# SSH Utilities
# ==============================================================================

get_ssh_key_option() {
    if [[ -f "$HOME/.ssh/homelab_admin" ]]; then
        echo "-i $HOME/.ssh/homelab_admin"
    fi
}

# ==============================================================================
# SSH Connectivity Testing
# ==============================================================================

test_ssh_connection() {
    log_section "Testing SSH Connection"

    log_info "Testing connection to ${SSH_TARGET}:${SSH_PORT}..."

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    if ssh_connection_succeeds "$ssh_key_opt"; then
        log_info "SSH connection successful"
    else
        log_ssh_connection_failure
        exit 1
    fi
}

ssh_connection_succeeds() {
    local ssh_key_opt="$1"
    ssh $ssh_key_opt -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p "$SSH_PORT" "$SSH_TARGET" "echo 'SSH connection successful'" &>/dev/null
}

log_ssh_connection_failure() {
    log_error "Failed to connect to Proxmox host"
    log_error "Please check:"
    log_error "  1. Proxmox host is reachable: ping ${PROXMOX_HOST}"
    log_error "  2. SSH is enabled on Proxmox"
    log_error "  3. SSH keys are configured (or password auth is enabled)"
    log_error "  4. Firewall allows SSH on port ${SSH_PORT}"
}

# ==============================================================================
# File Transfer
# ==============================================================================

copy_files_to_proxmox() {
    log_section "Copying Files to Proxmox"

    REMOTE_DIR="${REMOTE_DIR_PREFIX}-$(date +%s)"

    create_remote_directories
    copy_dr_scripts
    copy_config_file

    log_info "Files copied successfully"
}

create_remote_directories() {
    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    log_info "Creating remote directory: $REMOTE_DIR"
    # config/ is the destination for the env files SCPed by copy_config_file.
    # It used to be created implicitly by rsync when configs lived under
    # proxmox-dr/config/, but configs are now centralised in repo's configs/
    # so we mkdir it explicitly.
    ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "mkdir -p '$REMOTE_DIR/config'"
}

copy_dr_scripts() {
    log_info "Copying DR scripts to Proxmox..."

    local rsync_ssh_cmd
    rsync_ssh_cmd=$(build_rsync_ssh_command)

    rsync -az --progress \
        --exclude='.git' \
        --exclude='.DS_Store' \
        --exclude='*.md' \
        -e "$rsync_ssh_cmd" \
        "$PROXMOX_DR_DIR/" \
        "${SSH_TARGET}:${REMOTE_DIR}/"
}

copy_config_file() {
    log_info "Copying configuration files..."

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    # The DR config (configs/proxmox-dr.env on the Mac) is SCPed to the remote
    # as proxmox-config.env because that's the filename run-setup.sh looks for.
    scp $ssh_key_opt -P "$SSH_PORT" "$CONFIG_FILE" "${SSH_TARGET}:${REMOTE_DIR}/config/proxmox-config.env"

    # Shared homelab config goes alongside it so the DR config can source it
    # from the same directory at runtime.
    local homelab_config="${SCRIPT_DIR}/configs/homelab.env"
    if [[ -f "$homelab_config" ]]; then
        scp $ssh_key_opt -P "$SSH_PORT" "$homelab_config" "${SSH_TARGET}:${REMOTE_DIR}/config/homelab.env"
    fi
}

build_rsync_ssh_command() {
    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    if [[ -n "$ssh_key_opt" ]]; then
        echo "ssh $ssh_key_opt -p ${SSH_PORT}"
    else
        echo "ssh -p ${SSH_PORT}"
    fi
}

# ==============================================================================
# Remote Execution
# ==============================================================================

execute_remote_setup() {
    log_section "Executing Remote Setup"

    make_scripts_executable
    run_remote_setup_script
}

make_scripts_executable() {
    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    log_info "Making scripts executable..."
    ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "chmod +x '${REMOTE_DIR}/run-setup.sh' '${REMOTE_DIR}/lib/'*.sh"
}

run_remote_setup_script() {
    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    local ssh_pub_key_content
    ssh_pub_key_content=$(read_ssh_public_key)

    log_info "Starting Proxmox DR setup on remote host..."
    log_info "This will take 15-30 minutes. Output will stream below."
    echo ""

    if ssh $ssh_key_opt -t -p "$SSH_PORT" "$SSH_TARGET" "export SSH_PUBLIC_KEY_CONTENT='${ssh_pub_key_content}' && cd '${REMOTE_DIR}' && ./run-setup.sh"; then
        log_info "Remote setup completed successfully"
        return 0
    else
        log_remote_setup_failure "$ssh_key_opt"
        return 1
    fi
}

read_ssh_public_key() {
    if [[ -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
        cat "${SSH_PUBLIC_KEY_PATH}"
    fi
}

log_remote_setup_failure() {
    local ssh_key_opt="$1"

    log_error "Remote setup failed"
    log_warn "Remote files are preserved at: ${REMOTE_DIR}"
    log_warn "To debug: ssh $ssh_key_opt -p ${SSH_PORT} ${SSH_TARGET} 'cd ${REMOTE_DIR} && ./run-setup.sh'"
}

# ==============================================================================
# Cleanup
# ==============================================================================

cleanup_remote_files() {
    log_section "Cleaning Up"

    if [[ -z "${REMOTE_DIR:-}" ]]; then
        return 0
    fi

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    log_info "Removing remote directory: $REMOTE_DIR"
    ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "rm -rf '$REMOTE_DIR'" || true
    log_info "Cleanup complete"
}

# ==============================================================================
# Summary
# ==============================================================================

print_summary() {
    log_section "Deployment Complete!"

    echo "Proxmox host: ${PROXMOX_HOST}"
    echo ""
    echo "Proxmox DR setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. SSH to Proxmox: ssh root@${PROXMOX_HOST}"
    echo "  2. Deploy VMs and services manually or with your own scripts"
    echo ""
}

# ==============================================================================
# Script Execution
# ==============================================================================

main "$@"
