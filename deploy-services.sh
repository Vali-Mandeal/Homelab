#!/usr/bin/env bash
# ==============================================================================
# Homelab Service Deployment
# ==============================================================================
# Interactive menu for deploying services to Proxmox.
# Runs on your Mac - rsyncs files to Proxmox, then executes remotely.
# Usage: ./deploy-services.sh
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

SERVICE_NAMES=(portainer traefik homepage cloudflare-tunnel monitoring monitoring-agents jellyfin kasm   arr-stack nextcloud docs    n8n       scraper)
SERVICE_TYPES=(docker    docker  docker   docker            docker     docker              lxc      docker vm        vm        docker docker    docker)
SERVICE_DESCS=(
    "Centralized container management"
    "Reverse proxy with Let's Encrypt"
    "Dashboard"
    "Remote access tunnel"
    "Grafana + Prometheus + Loki + Alloy"
    "Alloy agents on all hosts"
    "Media server"
    "Browser isolation"
    "Media automation stack"
    "Personal cloud storage"
    "Docusaurus documentation sites (containers auto-discovered from private share; Traefik routes hand-managed in routes.yml)"
    "Workflow automation"
    "Web scraper stack (API + Admin UI) - 24/7 on CT 121"
)

SERVICE_COUNT=${#SERVICE_NAMES[@]}

# Tracks which services the user selected (0 = not selected, 1 = selected)
SELECTED=()
for ((i = 0; i < SERVICE_COUNT; i++)); do
    SELECTED+=(0)
done

# Mapping: service name → monitoring-agents host name
# Services not listed here have no corresponding agent
declare -A SERVICE_AGENT_HOST
SERVICE_AGENT_HOST=(
    [traefik]="traefik"
    [homepage]="homepage"
    [cloudflare-tunnel]="cloudflare-tunnel"
    [kasm]="kasm"
    [jellyfin]="jellyfin"
    [arr-stack]="media-server"
    [nextcloud]="nextcloud-vm"
    [n8n]="n8n"
    [scraper]="scraper"
)

# Agent hosts to deploy (populated by prompt_monitoring_agents)
AGENT_HOSTS=()

# Deploy mode: "full" (destroy+recreate LXC/VM) or "refresh" (reuse existing)
# Set by prompt_deploy_mode, consumed by lib/*-service.sh create_X functions
DEPLOY_MODE="full"

# Remote state
REMOTE_DIR=""
SSH_TARGET=""

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
    display_banner "Homelab Service Deployment"

    load_homelab_config
    show_main_menu
    prompt_deploy_mode
    prompt_monitoring_agents
    deploy_selected_services
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
    ssh $ssh_key_opt \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=30 \
        -p "$SSH_PORT" "$SSH_TARGET" "$@"
}

# ==============================================================================
# Main Menu
# ==============================================================================

show_main_menu() {
    echo "  Select deployment mode:"
    echo ""
    echo "    1) Deploy All Services"
    echo "    2) Deploy by Group"
    echo "    3) Deploy Custom Selection"
    echo "    4) Rollback Single Service"
    echo ""

    local choice
    read -r -p "  > " choice

    case "$choice" in
        1) select_all ;;
        2) show_group_menu ;;
        3) show_custom_menu ;;
        4) show_rollback_menu ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
}

# ==============================================================================
# Selection: Rollback Single Service
# ==============================================================================
# Lists services that have a rollback.sh next to their deploy.sh, lets the
# user pick one, and runs that service's rollback.sh via the same push-to-
# Proxmox + remote-execute flow used for deploys. Exits when done - skips
# prompt_deploy_mode / monitoring agent prompts since rollback isn't a deploy.

show_rollback_menu() {
    echo ""
    echo "  Select service to roll back:"
    echo ""

    local rollback_indices=()
    local n=0
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        local name="${SERVICE_NAMES[$i]}"
        local type="${SERVICE_TYPES[$i]}"
        if [[ -f "${SERVICES_DIR}/${type}/${name}/rollback.sh" ]]; then
            rollback_indices+=("$i")
            n=$((n + 1))
            printf "    %d) %-20s (%s)\n" "$n" "$name" "$type"
        fi
    done

    if [[ ${#rollback_indices[@]} -eq 0 ]]; then
        echo ""
        log_error "No services with rollback support found."
        log_info "A service supports rollback when it has rollback.sh next to deploy.sh."
        exit 1
    fi

    echo ""
    local choice
    read -r -p "  > " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] \
        || [[ "$choice" -lt 1 ]] \
        || [[ "$choice" -gt ${#rollback_indices[@]} ]]; then
        log_error "Invalid choice: $choice"
        exit 1
    fi

    local idx="${rollback_indices[$((choice - 1))]}"
    rollback_service "$idx"
    exit 0
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
    echo "    1) All Docker Containers  [portainer, traefik, homepage, cloudflare-tunnel, monitoring, monitoring-agents, kasm, scraper]"
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
# Deploy Mode Prompt
# ==============================================================================

prompt_deploy_mode() {
    echo ""
    echo "  Deploy mode:"
    echo ""
    echo "    1) Full     - destroy and recreate LXC/VM (clean slate)"
    echo "    2) Refresh  - keep existing LXC/VM, redeploy files & restart containers"
    echo ""

    local choice
    read -r -p "  > [1] " choice
    choice="${choice:-1}"

    case "$choice" in
        1) DEPLOY_MODE="full" ;;
        2) DEPLOY_MODE="refresh" ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac

    log_info "Deploy mode: ${DEPLOY_MODE}"
}

# ==============================================================================
# Monitoring Agent Prompt
# ==============================================================================

prompt_monitoring_agents() {
    # Skip if monitoring-agents is already selected (user explicitly chose it)
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        if [[ "${SERVICE_NAMES[$i]}" == "monitoring-agents" ]] && [[ "${SELECTED[$i]}" -eq 1 ]]; then
            return 0
        fi
    done

    # Collect agent hosts for selected services
    local agent_hosts=()
    for ((i = 0; i < SERVICE_COUNT; i++)); do
        if [[ "${SELECTED[$i]}" -eq 1 ]]; then
            local name="${SERVICE_NAMES[$i]}"
            local host="${SERVICE_AGENT_HOST[$name]:-}"
            if [[ -n "$host" ]]; then
                agent_hosts+=("$host")
            fi
        fi
    done

    # Nothing to offer if no selected services have agents
    if [[ ${#agent_hosts[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    log_info "These services have monitoring agents: ${agent_hosts[*]}"

    local choice
    read -r -p "  Deploy monitoring agents for selected services? [y/N] " choice

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        AGENT_HOSTS=("${agent_hosts[@]}")
        log_info "Will deploy monitoring agents after services"
    fi
}

# ==============================================================================
# Remote Deployment
# ==============================================================================

deploy_selected_services() {
    echo ""
    log_section "Deploying Services"

    # Test SSH connection
    log_info "Testing SSH connection to ${SSH_TARGET}..."
    if ! ssh_cmd "echo 'connected'" &>/dev/null; then
        log_error "Cannot connect to Proxmox at ${SSH_TARGET}:${SSH_PORT}"
        exit 1
    fi
    log_info "SSH connection OK"

    # Deploy in order: docker → lxc → vm
    local deploy_order=(docker lxc vm)

    for type in "${deploy_order[@]}"; do
        for ((i = 0; i < SERVICE_COUNT; i++)); do
            if [[ "${SELECTED[$i]}" -eq 1 ]] && [[ "${SERVICE_TYPES[$i]}" == "$type" ]]; then
                deploy_service "$i"
            fi
        done
    done

    # Deploy monitoring agents if requested
    if [[ ${#AGENT_HOSTS[@]} -gt 0 ]]; then
        deploy_monitoring_agents
    fi

    log_section "All Deployments Complete"
}

deploy_monitoring_agents() {
    log_section "Deploying Monitoring Agents: ${AGENT_HOSTS[*]}"

    local name="monitoring-agents"
    local type="docker"
    local local_service_dir="${SERVICES_DIR}/${type}/${name}"

    if [[ ! -f "${local_service_dir}/deploy.sh" ]]; then
        log_warn "Skipping monitoring agents - deploy script not found"
        return 0
    fi

    REMOTE_DIR="/tmp/homelab-deploy-${name}-$(date +%s)"

    push_files_to_proxmox "$name" "$type" "$local_service_dir"
    execute_remote_deploy "$name" "$type" "${AGENT_HOSTS[@]}"
    cleanup_remote "$name"
}

deploy_service() {
    local idx="$1"
    local name="${SERVICE_NAMES[$idx]}"
    local type="${SERVICE_TYPES[$idx]}"

    local local_service_dir="${SERVICES_DIR}/${type}/${name}"
    local local_deploy_script="${local_service_dir}/deploy.sh"

    if [[ ! -f "$local_deploy_script" ]]; then
        log_warn "Skipping ${name} (${type}) - deploy script not found: ${type}/${name}/deploy.sh"
        return 0
    fi

    log_section "Deploying: ${name} (${type})"

    REMOTE_DIR="/tmp/homelab-deploy-${name}-$(date +%s)"

    push_files_to_proxmox "$name" "$type" "$local_service_dir"
    execute_remote_deploy "$name" "$type"
    cleanup_remote "$name"

    # For VMs, add an SSH config entry on the local Mac
    if [[ "$type" == "vm" ]]; then
        update_local_ssh_config "$name" "$local_service_dir"
    fi
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

    # Copy homelab SSH private key - used by n8n credential automation
    if [[ -f "$HOME/.ssh/homelab_admin" ]]; then
        scp $scp_opts "$HOME/.ssh/homelab_admin" "${SSH_TARGET}:${REMOTE_DIR}/config/homelab_admin_key"
        ssh_cmd "chmod 600 '${REMOTE_DIR}/config/homelab_admin_key'"
    fi

    # Copy service directory via rsync - incremental, excludes build artefacts,
    # picks up dotfiles automatically. Avoids the per-file SCP storm that hits
    # ~10k requests for any service with node_modules/.
    rsync -az --delete \
        --exclude='node_modules' \
        --exclude='dist' \
        --exclude='build' \
        --exclude='.vite' \
        --exclude='.cache' \
        --exclude='.parcel-cache' \
        --exclude='.git' \
        --exclude='bin' \
        --exclude='obj' \
        --exclude='.DS_Store' \
        --exclude='config.env' \
        --exclude='.env' \
        -e "ssh $ssh_key_opt -p ${SSH_PORT}" \
        "${local_service_dir}/" "${SSH_TARGET}:${REMOTE_DIR}/${type}/${name}/"

    # Copy per-service config (configs/<name>.env → service dir as config.env).
    # Done AFTER rsync so --delete can't wipe it; --exclude above is belt-and-braces.
    # Service deploy.sh keeps sourcing ${SCRIPT_DIR}/config.env unchanged.
    if [[ -f "${SCRIPT_DIR}/configs/${name}.env" ]]; then
        scp $scp_opts "${SCRIPT_DIR}/configs/${name}.env" "${SSH_TARGET}:${REMOTE_DIR}/${type}/${name}/config.env"
    fi

    # Copy per-service RUNTIME env (configs/<name>.runtime.env → service dir as .env).
    # This is the docker-compose runtime template (passwords, secrets, paths)
    # that gets pushed to the VM/CT as /opt/<name>/.env. Lives in configs/ rather
    # than alongside docker-compose.yml so all secret-bearing files share one
    # gitignored location.
    # Substituted via envsubst on TRAEFIK_DOMAIN/PUBLIC_DOMAIN so the runtime
    # .env on the VM has literal host strings - Docker Compose does not do
    # recursive var resolution between .env entries.
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

execute_remote_deploy() {
    local name="$1"
    local type="$2"
    shift 2
    local extra_args=("$@")

    log_info "Executing deploy on Proxmox..."

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    ssh $ssh_key_opt -t \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=30 \
        -p "$SSH_PORT" "$SSH_TARGET" \
        "chmod +x '${REMOTE_DIR}/${type}/${name}/deploy.sh' && cd '${REMOTE_DIR}' && DEPLOY_MODE='${DEPLOY_MODE}' bash '${type}/${name}/deploy.sh' ${extra_args[*]:-}"
}

# ==============================================================================
# Rollback Service
# ==============================================================================
# Mirrors deploy_service: sync files to Proxmox, run rollback.sh remotely,
# clean up. Used only by show_rollback_menu (option 4).

rollback_service() {
    local idx="$1"
    local name="${SERVICE_NAMES[$idx]}"
    local type="${SERVICE_TYPES[$idx]}"

    local local_service_dir="${SERVICES_DIR}/${type}/${name}"
    local local_rollback_script="${local_service_dir}/rollback.sh"

    if [[ ! -f "$local_rollback_script" ]]; then
        log_error "rollback.sh not found for ${name}: ${type}/${name}/rollback.sh"
        exit 1
    fi

    log_section "Rolling back: ${name} (${type})"

    REMOTE_DIR="/tmp/homelab-rollback-${name}-$(date +%s)"

    push_files_to_proxmox "$name" "$type" "$local_service_dir"
    execute_remote_rollback "$name" "$type"
    cleanup_remote "$name"
}

execute_remote_rollback() {
    local name="$1"
    local type="$2"

    log_info "Executing rollback on Proxmox..."

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    ssh $ssh_key_opt -t \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=30 \
        -p "$SSH_PORT" "$SSH_TARGET" \
        "chmod +x '${REMOTE_DIR}/${type}/${name}/rollback.sh' && cd '${REMOTE_DIR}' && bash '${type}/${name}/rollback.sh'"
}

cleanup_remote() {
    local name="$1"

    if [[ -n "${REMOTE_DIR:-}" ]]; then
        log_info "Cleaning up remote files..."
        ssh_cmd "rm -rf '${REMOTE_DIR}'" 2>/dev/null || true
    fi
}

# ==============================================================================
# Local SSH Config (for VMs)
# ==============================================================================

update_local_ssh_config() {
    local name="$1"
    local local_service_dir="$2"
    local config_file="${local_service_dir}/config.env"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Source the service config to get VM_NAME, VM_IP, VM_SSH_ALIAS
    local VM_NAME="" VM_IP="" VM_SSH_ALIAS=""
    source "$config_file"

    if [[ "${VM_SSH_ALIAS}" != "true" ]]; then
        return 0
    fi

    local ssh_config="$HOME/.ssh/config"
    local key_path="$HOME/.ssh/homelab_admin"

    # Check if entry already exists - update IP if changed, skip if identical
    if grep -q "^Host ${VM_NAME}$" "$ssh_config" 2>/dev/null; then
        local existing_ip
        existing_ip=$(awk "/^Host ${VM_NAME}$/{found=1} found && /HostName/{print \$2; exit}" "$ssh_config")
        if [[ "$existing_ip" == "$VM_IP" ]]; then
            log_info "SSH config already has entry for ${VM_NAME}"
            return 0
        fi
        # Remove old entry and re-add with new IP
        log_info "Updating SSH config entry for ${VM_NAME} (IP changed to ${VM_IP})"
        remove_ssh_config_entry "$VM_NAME" "$ssh_config"
    fi

    log_info "Adding SSH config entry: ssh ${VM_NAME} → ${VM_IP}"

    cat >> "$ssh_config" << EOF

# ${VM_NAME} VM (Auto-generated by deploy)
Host ${VM_NAME}
    HostName ${VM_IP}
    User root
    IdentityFile ${key_path}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

    chmod 600 "$ssh_config"
    log_info "You can now use: ssh ${VM_NAME}"
}

remove_ssh_config_entry() {
    local host_name="$1"
    local ssh_config="$2"

    # Remove the comment line, Host block, and all indented lines that follow
    local tmp_file
    tmp_file=$(mktemp)
    awk -v host="$host_name" '
        /^# .* VM \(Auto-generated/ { skip_comment=1; next }
        /^Host / { if ($2 == host) { skip=1; next } else { skip=0 } }
        skip && /^[[:space:]]/ { next }
        skip && /^[^[:space:]]/ { skip=0 }
        !skip_comment { print }
        { skip_comment=0 }
    ' "$ssh_config" > "$tmp_file"
    mv "$tmp_file" "$ssh_config"
}

# ==============================================================================
# Cleanup on Exit
# ==============================================================================

cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ -n "${REMOTE_DIR:-}" ]] && [[ -n "${SSH_TARGET:-}" ]]; then
        log_warn "Deployment failed. Remote files preserved at: ${REMOTE_DIR}"
    fi
}

trap cleanup_on_exit EXIT

# ==============================================================================
# Script Execution
# ==============================================================================

main "$@"
