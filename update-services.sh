#!/usr/bin/env bash
# ==============================================================================
# Homelab Service Update
# ==============================================================================
# Interactive menu for updating services on Proxmox.
# Runs on your Mac - syncs update scripts to Proxmox, then executes remotely.
# Usage: ./update-services.sh
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="${SCRIPT_DIR}/services"

source "${SERVICES_DIR}/lib/common.sh"

# ==============================================================================
# Service Registry
# ==============================================================================
# Parallel arrays - bash 3.2 compatible (macOS)

SERVICE_NAMES=(traefik homepage cloudflare-tunnel monitoring monitoring-agents jellyfin kasm   arr-stack nextcloud n8n    scraper)
SERVICE_TYPES=(docker  docker   docker            docker     docker              lxc      docker vm        vm        docker docker)
SERVICE_DESCS=(
    "Reverse proxy with Let's Encrypt"
    "Dashboard"
    "Remote access tunnel"
    "Grafana + Prometheus + Loki + Alloy"
    "Alloy agents on all hosts"
    "Media server"
    "Browser isolation"
    "Media automation stack"
    "Personal cloud storage"
    "Workflow automation"
    "Web scraper stack (API + Admin UI) - 24/7 on CT 121"
)

SERVICE_COUNT=${#SERVICE_NAMES[@]}

# Tracks which services the user selected (0 = not selected, 1 = selected)
SELECTED=()
for ((i = 0; i < SERVICE_COUNT; i++)); do
    SELECTED+=(0)
done

# Remote state
REMOTE_DIR=""
SSH_TARGET=""

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
    display_banner "Homelab Service Update"

    load_homelab_config
    show_main_menu
    update_selected_services
}

# ==============================================================================
# Configuration
# ==============================================================================

load_homelab_config() {
    local config_file="${SCRIPT_DIR}/configs/homelab.env"

    if [[ ! -f "$config_file" ]]; then
        log_error "Shared config not found: ${config_file}"
        log_info "Copy configs/homelab.env.example to configs/homelab.env and customize it."
        exit 1
    fi

    source "$config_file"

    SSH_PORT="${SSH_PORT:-22}"
    SSH_TARGET="${SSH_USER}@${PROXMOX_HOST}"
}

# ==============================================================================
# SSH Utilities
# ==============================================================================

get_ssh_key_option() {
    if [[ -f "$HOME/.ssh/homelab_admin" ]]; then
        echo "-i $HOME/.ssh/homelab_admin"
    fi
}

ssh_cmd() {
    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)
    ssh $ssh_key_opt -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p "$SSH_PORT" "$SSH_TARGET" "$@"
}

# ==============================================================================
# Main Menu
# ==============================================================================

show_main_menu() {
    echo "  Select update mode:"
    echo ""
    echo "    1) Update All Services"
    echo "    2) Update by Group"
    echo "    3) Update Custom Selection"
    echo ""

    local choice
    read -r -p "  > " choice

    case "$choice" in
        1) select_all ;;
        2) show_group_menu ;;
        3) show_custom_menu ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
}

# ==============================================================================
# Selection: All
# ==============================================================================

select_all() {
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        SELECTED[$i]=1
    done
    log_info "Selected all services"
}

# ==============================================================================
# Selection: By Group
# ==============================================================================

show_group_menu() {
    echo ""
    echo "  Select group:"
    echo ""
    echo "    1) All Docker Containers  [traefik, homepage, cloudflare-tunnel, monitoring, kasm, n8n, scraper]"
    echo "    2) All LXC Containers     [jellyfin]"
    echo "    3) All VMs                [arr-stack, nextcloud]"
    echo ""

    local choice
    read -r -p "  > " choice

    local target_type
    case "$choice" in
        1) target_type="docker" ;;
        2) target_type="lxc" ;;
        3) target_type="vm" ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac

    local count=0
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        if [[ "${SERVICE_TYPES[$i]}" == "$target_type" ]]; then
            SELECTED[$i]=1
            count=$((count + 1))
        fi
    done

    log_info "Selected $count $target_type service(s)"
}

# ==============================================================================
# Selection: Custom
# ==============================================================================

show_custom_menu() {
    echo ""
    log_info "Toggle services by entering their number. Press enter when done."
    echo ""

    while true; do
        print_custom_list
        echo ""

        local input
        read -r -p "  Toggle (or press enter to confirm): " input

        if [[ -z "$input" ]]; then
            break
        fi

        if ! [[ "$input" =~ ^[0-9]+$ ]]; then
            log_warn "Enter a number between 1 and $SERVICE_COUNT"
            continue
        fi

        local idx=$((input - 1))
        if [[ $idx -lt 0 ]] || [[ $idx -ge $SERVICE_COUNT ]]; then
            log_warn "Enter a number between 1 and $SERVICE_COUNT"
            continue
        fi

        if [[ "${SELECTED[$idx]}" -eq 0 ]]; then
            SELECTED[$idx]=1
        else
            SELECTED[$idx]=0
        fi
    done

    local count=0
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        if [[ "${SELECTED[$i]}" -eq 1 ]]; then
            count=$((count + 1))
        fi
    done

    if [[ $count -eq 0 ]]; then
        log_warn "No services selected"
        exit 0
    fi

    log_info "Selected $count service(s)"
}

print_custom_list() {
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        local marker=" "
        if [[ "${SELECTED[$i]}" -eq 1 ]]; then
            marker="x"
        fi
        printf "    %d) [%s] %-20s (%s)\n" $((i + 1)) "$marker" "${SERVICE_NAMES[$i]}" "${SERVICE_TYPES[$i]}"
    done
}

# ==============================================================================
# Remote Update Execution
# ==============================================================================

update_selected_services() {
    echo ""
    log_section "Updating Services"

    # Test SSH connection
    log_info "Testing SSH connection to ${SSH_TARGET}..."
    if ! ssh_cmd "echo 'connected'" &>/dev/null; then
        log_error "Cannot connect to Proxmox at ${SSH_TARGET}:${SSH_PORT}"
        exit 1
    fi
    log_info "SSH connection OK"

    # Update in order: docker -> lxc -> vm
    local update_order=(docker lxc vm)

    for type in "${update_order[@]}"; do
        for ((i = 0; i < SERVICE_COUNT; i++)); do
            if [[ "${SELECTED[$i]}" -eq 1 ]] && [[ "${SERVICE_TYPES[$i]}" == "$type" ]]; then
                update_service "$i"
            fi
        done
    done

    log_section "All Updates Complete"
}

update_service() {
    local idx="$1"
    local name="${SERVICE_NAMES[$idx]}"
    local type="${SERVICE_TYPES[$idx]}"

    local local_service_dir="${SERVICES_DIR}/${type}/${name}"
    local local_update_script="${local_service_dir}/update.sh"

    if [[ ! -f "$local_update_script" ]]; then
        log_warn "Skipping ${name} (${type}) - update script not found: ${type}/${name}/update.sh"
        return 0
    fi

    log_section "Updating: ${name} (${type})"

    REMOTE_DIR="/tmp/homelab-update-${name}-$(date +%s)"

    push_files_to_proxmox "$name" "$type" "$local_service_dir"
    execute_remote_update "$name" "$type"
    cleanup_remote "$name"
}

push_files_to_proxmox() {
    local name="$1"
    local type="$2"
    local local_service_dir="$3"

    log_info "Copying files to Proxmox..."

    # Create remote directory structure
    ssh_cmd "mkdir -p '${REMOTE_DIR}/lib' '${REMOTE_DIR}/${type}/${name}' '${REMOTE_DIR}/config'"

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)
    local scp_opts="$ssh_key_opt -P ${SSH_PORT}"

    # Copy shared libraries
    scp $scp_opts "${SERVICES_DIR}/lib/"*.sh "${SSH_TARGET}:${REMOTE_DIR}/lib/"

    # Copy shared config
    if [[ -f "${SCRIPT_DIR}/configs/homelab.env" ]]; then
        scp $scp_opts "${SCRIPT_DIR}/configs/homelab.env" "${SSH_TARGET}:${REMOTE_DIR}/config/homelab.env"
    fi

    # Copy service directory (all files, including dotfiles)
    scp $scp_opts -r "${local_service_dir}/"* "${SSH_TARGET}:${REMOTE_DIR}/${type}/${name}/"
    for dotfile in "${local_service_dir}"/.*; do
        [[ -f "$dotfile" ]] && scp $scp_opts "$dotfile" "${SSH_TARGET}:${REMOTE_DIR}/${type}/${name}/"
    done

    # Copy per-service config (configs/<name>.env → service dir as config.env).
    # Done AFTER the service dir copy so a stray local config.env can't shadow it.
    if [[ -f "${SCRIPT_DIR}/configs/${name}.env" ]]; then
        scp $scp_opts "${SCRIPT_DIR}/configs/${name}.env" "${SSH_TARGET}:${REMOTE_DIR}/${type}/${name}/config.env"
    fi

    # Copy per-service RUNTIME env (configs/<name>.runtime.env → service dir as .env).
    # Mirror of the same step in deploy-services.sh - envsubst on the two domain
    # vars so the .env on the VM holds literal hostnames (Docker Compose does not
    # resolve nested ${VAR}s between .env entries).
    if [[ -f "${SCRIPT_DIR}/configs/${name}.runtime.env" ]]; then
        local tmp_runtime
        tmp_runtime=$(mktemp)
        (
            set -a
            source "${SCRIPT_DIR}/configs/homelab.env"
            set +a
            envsubst '${TRAEFIK_DOMAIN} ${PUBLIC_DOMAIN}' < "${SCRIPT_DIR}/configs/${name}.runtime.env" > "$tmp_runtime"
        )
        scp $scp_opts "$tmp_runtime" "${SSH_TARGET}:${REMOTE_DIR}/${type}/${name}/.env"
        rm -f "$tmp_runtime"
    fi

    log_info "Files copied"
}

execute_remote_update() {
    local name="$1"
    local type="$2"

    log_info "Executing update on Proxmox..."

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    ssh $ssh_key_opt -t -p "$SSH_PORT" "$SSH_TARGET" \
        "chmod +x '${REMOTE_DIR}/${type}/${name}/update.sh' && cd '${REMOTE_DIR}' && bash '${type}/${name}/update.sh'"
}

cleanup_remote() {
    local name="$1"

    if [[ -n "${REMOTE_DIR:-}" ]]; then
        log_info "Cleaning up remote files..."
        ssh_cmd "rm -rf '${REMOTE_DIR}'" 2>/dev/null || true
    fi
}

# ==============================================================================
# Cleanup on Exit
# ==============================================================================

cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ -n "${REMOTE_DIR:-}" ]] && [[ -n "${SSH_TARGET:-}" ]]; then
        log_warn "Update failed. Remote files preserved at: ${REMOTE_DIR}"
    fi
}

trap cleanup_on_exit EXIT

# ==============================================================================
# Script Execution
# ==============================================================================

main "$@"
