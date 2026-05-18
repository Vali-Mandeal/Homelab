#!/usr/bin/env bash
# ==============================================================================
# Deploy Alloy Monitoring Agents to All Hosts
# ==============================================================================
# Runs ON Proxmox. Installs Grafana Alloy on each LXC, VM, and the Proxmox
# host itself. Each agent pushes metrics to Prometheus and logs to Loki on
# the monitoring LXC (CT 117).
#
# Invoke via the standard deploy-services.sh orchestrator, or directly on Proxmox:
#   ./deploy.sh [host...]
#     No arguments = deploy to all hosts
#     With arguments = deploy only to named hosts (e.g. "proxmox traefik")
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."
AGENTS_DIR="${SCRIPT_DIR}/agents"

source "${DEPLOY_ROOT}/lib/common.sh"

# Per-deploy host registry (IPs + CT/VM IDs).
# Defines: MONITORING_CT_IP, HOST_IP[], HOST_CT_ID[], HOST_VM_ID[]
# Looks in two places: orchestrator push location, then in-repo location.
HOST_REGISTRY=""
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    HOST_REGISTRY="${SCRIPT_DIR}/config.env"
elif [[ -f "${SCRIPT_DIR}/../../../configs/monitoring-agents.env" ]]; then
    HOST_REGISTRY="${SCRIPT_DIR}/../../../configs/monitoring-agents.env"
fi

if [[ -n "$HOST_REGISTRY" ]]; then
    source "$HOST_REGISTRY"
else
    log_error "Host registry not found"
    log_info "Copy configs/monitoring-agents.env.example to configs/monitoring-agents.env and fill in your IPs/IDs."
    exit 1
fi

# ==============================================================================
# Host Registry - types and per-host config templates (non-sensitive metadata)
# ==============================================================================

ALL_HOSTS=(proxmox traefik homepage kasm cloudflare-tunnel nextcloud-vm media-server jellyfin n8n scraper)

declare -A HOST_TYPE=(
    [proxmox]="local"
    [traefik]="lxc"
    [homepage]="lxc"
    [kasm]="lxc"
    [cloudflare-tunnel]="lxc"
    [nextcloud-vm]="vm"
    [media-server]="vm"
    [jellyfin]="lxc"
    [n8n]="lxc"
    [scraper]="lxc"
)

# Which config file each host uses
declare -A HOST_CONFIG=(
    [proxmox]="proxmox-agent.alloy"
    [traefik]="docker-agent.alloy"
    [homepage]="docker-agent.alloy"
    [kasm]="docker-agent.alloy"
    [cloudflare-tunnel]="docker-agent.alloy"
    [nextcloud-vm]="nextcloud-agent.alloy"
    [media-server]="arr-agent.alloy"
    [jellyfin]="jellyfin-agent.alloy"
    [n8n]="docker-agent.alloy"
    [scraper]="docker-agent.alloy"
)

# Hosts that need docker group access for the alloy user
declare -A HOST_NEEDS_DOCKER=(
    [traefik]="1"
    [homepage]="1"
    [kasm]="1"
    [cloudflare-tunnel]="1"
    [nextcloud-vm]="1"
    [media-server]="1"
    [n8n]="1"
    [scraper]="1"
)

# ==============================================================================
# Alloy Installation Commands (idempotent)
# ==============================================================================

ALLOY_INSTALL_CMD='
export DEBIAN_FRONTEND=noninteractive
if command -v alloy &>/dev/null; then
    echo "Alloy already installed"
else
    apt-get install -y -qq gpg wget > /dev/null 2>&1
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    apt-get install -y alloy
    echo "Alloy installed successfully"
fi
'

# ==============================================================================
# SSH Helpers (for VMs)
# ==============================================================================

ssh_to_vm() {
    local vm_ip="$1"
    shift
    local key_opt=""
    if [[ -f "/root/.ssh/homelab_admin" ]]; then
        key_opt="-i /root/.ssh/homelab_admin"
    fi
    ssh $key_opt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        "root@${vm_ip}" "$@"
}

scp_to_vm() {
    local vm_ip="$1"
    local src="$2"
    local dest="$3"
    local key_opt=""
    if [[ -f "/root/.ssh/homelab_admin" ]]; then
        key_opt="-i /root/.ssh/homelab_admin"
    fi
    scp $key_opt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        "$src" "root@${vm_ip}:${dest}"
}

# ==============================================================================
# Config File Generation
# ==============================================================================

generate_config() {
    local host_name="$1"
    local config_src="${AGENTS_DIR}/${HOST_CONFIG[$host_name]}"
    local config_dest="/tmp/alloy-config-${host_name}.alloy"

    if [[ ! -f "$config_src" ]]; then
        log_error "Config file not found: ${config_src}"
        return 1
    fi

    # Substitute placeholders in every agent file:
    #   __HOST__           → hostname (only used by docker-agent.alloy)
    #   __IP__             → this host's IP
    #   __MONITORING_IP__  → monitoring CT IP (Prometheus + Loki receiver)
    #   __LOG_PATH__       → file-based log glob for this host (jellyfin, nextcloud, media-server)
    local log_path="${HOST_LOG_PATH[$host_name]:-}"
    sed "s|__HOST__|${host_name}|g; \
         s|__IP__|${HOST_IP[$host_name]}|g; \
         s|__MONITORING_IP__|${MONITORING_CT_IP}|g; \
         s|__LOG_PATH__|${log_path}|g" \
        "$config_src" > "$config_dest"

    echo "$config_dest"
}

# ==============================================================================
# Deploy to Proxmox Host (local)
# ==============================================================================

deploy_to_proxmox() {
    log_section "Deploying Alloy Agent: Proxmox Host"

    # Install lm-sensors for temperature monitoring
    if ! command -v sensors &>/dev/null; then
        log_info "Installing lm-sensors for temperature monitoring..."
        apt-get install -y -qq lm-sensors > /dev/null 2>&1
        sensors-detect --auto > /dev/null 2>&1 || true
    fi

    # Install Alloy
    log_info "Installing Alloy..."
    bash -c "$ALLOY_INSTALL_CMD"

    # Deploy config
    local config_file
    config_file=$(generate_config "proxmox")
    cp "$config_file" /etc/alloy/config.alloy
    rm -f "$config_file"

    # Alloy needs journal access
    usermod -aG systemd-journal alloy 2>/dev/null || true

    # Enable and restart
    systemctl enable alloy
    systemctl restart alloy

    log_info "Alloy agent deployed on Proxmox host"
}

# ==============================================================================
# Deploy to LXC Container (via pct exec)
# ==============================================================================

deploy_to_lxc() {
    local host_name="$1"
    local ct_id="${HOST_CT_ID[$host_name]}"

    log_section "Deploying Alloy Agent: ${host_name} (CT ${ct_id})"

    # Check container is running
    if ! pct status "$ct_id" 2>/dev/null | grep -q "running"; then
        log_warn "Container ${ct_id} is not running - skipping ${host_name}"
        return 1
    fi

    # Install Alloy
    log_info "Installing Alloy in CT ${ct_id}..."
    pct exec "$ct_id" -- bash -c "$ALLOY_INSTALL_CMD"

    # Generate and push config
    local config_file
    config_file=$(generate_config "$host_name")
    pct push "$ct_id" "$config_file" /etc/alloy/config.alloy
    rm -f "$config_file"

    # Docker group access if needed
    if [[ -n "${HOST_NEEDS_DOCKER[$host_name]:-}" ]]; then
        pct exec "$ct_id" -- bash -c "usermod -aG docker alloy 2>/dev/null || true"
    fi

    # Enable and restart
    pct exec "$ct_id" -- bash -c "systemctl enable alloy && systemctl restart alloy"

    log_info "Alloy agent deployed to ${host_name} (CT ${ct_id})"
}

# ==============================================================================
# Deploy to VM (via SSH)
# ==============================================================================

deploy_to_vm() {
    local host_name="$1"
    local vm_id="${HOST_VM_ID[$host_name]}"
    local vm_ip="${HOST_IP[$host_name]}"
    local ssh_was_disabled=false

    log_section "Deploying Alloy Agent: ${host_name} (VM ${vm_id})"

    # Check VM is running
    if ! qm status "$vm_id" 2>/dev/null | grep -q "running"; then
        log_warn "VM ${vm_id} is not running - skipping ${host_name}"
        return 1
    fi

    # Check if SSH is accessible
    if ! ssh_to_vm "$vm_ip" "echo ready" &>/dev/null; then
        log_warn "${host_name}: SSH not accessible, attempting to enable via guest agent..."
        qm guest exec "$vm_id" -- bash -c "systemctl start ssh" 2>/dev/null || true
        sleep 3

        if ! ssh_to_vm "$vm_ip" "echo ready" &>/dev/null; then
            log_error "${host_name}: Cannot reach VM - skipping"
            return 1
        fi
        ssh_was_disabled=true
        log_info "SSH temporarily enabled"
    fi

    # Install Alloy
    log_info "Installing Alloy on ${host_name}..."
    ssh_to_vm "$vm_ip" "$ALLOY_INSTALL_CMD"

    # Generate and push config
    local config_file
    config_file=$(generate_config "$host_name")
    scp_to_vm "$vm_ip" "$config_file" /etc/alloy/config.alloy
    rm -f "$config_file"

    # Docker group access if needed
    if [[ -n "${HOST_NEEDS_DOCKER[$host_name]:-}" ]]; then
        ssh_to_vm "$vm_ip" "usermod -aG docker alloy 2>/dev/null || true"
    fi

    # Enable and restart
    ssh_to_vm "$vm_ip" "systemctl enable alloy && systemctl restart alloy"

    # Re-disable SSH if we enabled it
    if [[ "$ssh_was_disabled" == "true" ]]; then
        ssh_to_vm "$vm_ip" "systemctl stop ssh && systemctl disable ssh"
        log_info "${host_name}: SSH re-disabled"
    fi

    log_info "Alloy agent deployed to ${host_name} (VM ${vm_id})"
}

# ==============================================================================
# Deploy Single Host
# ==============================================================================

deploy_host() {
    local host_name="$1"
    local host_type="${HOST_TYPE[$host_name]}"

    case "$host_type" in
        local) deploy_to_proxmox ;;
        lxc)   deploy_to_lxc "$host_name" ;;
        vm)    deploy_to_vm "$host_name" ;;
        *)     log_error "Unknown host type: ${host_type}" ;;
    esac
}

# ==============================================================================
# Verification
# ==============================================================================

verify_agents() {
    log_section "Verifying Agents"

    local success=0
    local failed=0

    for host_name in "${DEPLOY_TARGETS[@]}"; do
        local host_type="${HOST_TYPE[$host_name]}"
        local status="unknown"

        case "$host_type" in
            local)
                status=$(systemctl is-active alloy 2>/dev/null || echo "inactive")
                ;;
            lxc)
                local ct_id="${HOST_CT_ID[$host_name]}"
                status=$(pct exec "$ct_id" -- systemctl is-active alloy 2>/dev/null || echo "inactive")
                ;;
            vm)
                local vm_ip="${HOST_IP[$host_name]}"
                status=$(ssh_to_vm "$vm_ip" "systemctl is-active alloy" 2>/dev/null || echo "inactive")
                ;;
        esac

        if [[ "$status" == "active" ]]; then
            log_info "${host_name}: Alloy is running"
            success=$((success + 1))
        else
            log_warn "${host_name}: Alloy is NOT running (${status})"
            failed=$((failed + 1))
        fi
    done

    echo ""
    log_info "Agents running: ${success}/${#DEPLOY_TARGETS[@]}"

    if [[ $failed -gt 0 ]]; then
        log_warn "${failed} agent(s) failed - check logs with: journalctl -u alloy"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploy Alloy Monitoring Agents"

    # Determine which hosts to deploy
    if [[ $# -gt 0 ]]; then
        DEPLOY_TARGETS=("$@")
        # Validate host names
        for host in "${DEPLOY_TARGETS[@]}"; do
            if [[ -z "${HOST_TYPE[$host]:-}" ]]; then
                log_error "Unknown host: ${host}"
                log_info "Valid hosts: ${ALL_HOSTS[*]}"
                exit 1
            fi
        done
    else
        DEPLOY_TARGETS=("${ALL_HOSTS[@]}")
    fi

    log_info "Deploying to: ${DEPLOY_TARGETS[*]}"
    echo ""

    local total_success=0
    local total_failed=0

    for host_name in "${DEPLOY_TARGETS[@]}"; do
        if deploy_host "$host_name"; then
            total_success=$((total_success + 1))
        else
            total_failed=$((total_failed + 1))
        fi
    done

    verify_agents

    log_section "Agent Deployment Complete"
    echo "  Successful: ${total_success}"
    echo "  Failed:     ${total_failed}"
    echo ""
    echo "  Metrics:  All hosts → Prometheus at ${MONITORING_CT_IP}:9090"
    echo "  Logs:     All hosts → Loki at ${MONITORING_CT_IP}:3100"
    echo "  Dashboard: http://${MONITORING_CT_IP}:3001 (Grafana)"
    echo ""
}

main "$@"
