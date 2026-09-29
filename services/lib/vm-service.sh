#!/usr/bin/env bash
# ==============================================================================
# Shared VM Service Functions
# ==============================================================================
# Common functions for deploying services inside QEMU/KVM virtual machines.
# Runs ON Proxmox. Sourced by individual service deploy scripts.
#
# Required variables (set by service config.env before calling):
#   VM_ID, VM_NAME, VM_IP, VM_MEMORY, VM_CORES, VM_DISK, VM_BRIDGE
# Optional:
#   VM_VLAN_TAG, VM_STORAGE (defaults to local-lvm), VM_SSH_PASSWORD
# ==============================================================================

# ==============================================================================
# VM Creation (Orchestrator)
# ==============================================================================

create_vm() {
    log_section "Creating VM: ${VM_NAME} (${VM_ID})"

    # Refresh mode: skip clone+cloud-init, just ensure existing VM is running
    if [[ "${DEPLOY_MODE:-full}" == "refresh" ]]; then
        if reuse_existing_vm; then
            return 0
        fi
        log_warn "Falling back to full create"
    fi

    local storage="${VM_STORAGE:-local-lvm}"

    destroy_existing_vm
    clone_from_golden_image "$storage"
    configure_vm_hardware
    configure_vm_network
    resize_vm_disk "$storage"
    configure_cloud_init
    start_and_wait_vm

    wait_for_cloud_init
    install_qemu_guest_agent
    configure_vm_ssh
    log_info "VM ${VM_NAME} (${VM_ID}) ready at ${VM_IP}"
}

# Returns 0 if existing VM was successfully reused, non-zero otherwise.
reuse_existing_vm() {
    if ! qm status "$VM_ID" &>/dev/null; then
        log_warn "Refresh requested but VM ${VM_ID} doesn't exist"
        return 1
    fi

    log_info "Refresh mode: reusing existing VM ${VM_ID}"

    # Start if not already running
    local current_status
    current_status=$(qm status "$VM_ID" 2>/dev/null | awk '{print $2}')
    if [[ "$current_status" != "running" ]]; then
        log_info "Starting VM ${VM_ID}..."
        qm start "$VM_ID" 2>/dev/null || true
    fi

    # Wait for SSH to be reachable
    local timeout=60
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ssh_vm "echo ready" &>/dev/null; then
            log_info "VM ${VM_NAME} (${VM_ID}) ready at ${VM_IP}"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_warn "VM ${VM_ID} exists but SSH did not respond within ${timeout}s"
    return 1
}

install_qemu_guest_agent() {
    log_info "Installing qemu-guest-agent..."
    ssh_vm "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq qemu-guest-agent > /dev/null 2>&1
        systemctl enable --now qemu-guest-agent
    "
}

wait_for_cloud_init() {
    # Poll cloud-init status in a loop instead of `cloud-init status --wait`.
    # --wait is a single SSH that blocks silently for however long cloud-init
    # takes; the outer SSH from Mac→Proxmox sees no traffic and gets reset by
    # ISP / NAT middleboxes after a few idle minutes. Polling opens short SSH
    # sessions and emits a log line each iteration, which keeps the outer
    # session visibly alive and gives us a hard timeout.
    local timeout="${CLOUD_INIT_TIMEOUT:-900}"   # 15 min default
    local interval=15
    local elapsed=0

    log_info "Waiting for cloud-init to finish (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(ssh_vm "cloud-init status 2>/dev/null | awk -F': ' '/status:/ {print \$2}'" 2>/dev/null \
                 | tr -d '[:space:]' || echo "")

        case "$status" in
            done|disabled)
                log_info "cloud-init: ${status} (after ${elapsed}s)"
                break
                ;;
            error)
                log_warn "cloud-init reported error - proceeding anyway"
                break
                ;;
            "")
                # No status yet (transient SSH or cloud-init hasn't started)
                log_info "  cloud-init: probing... (${elapsed}s elapsed)"
                ;;
            *)
                log_info "  cloud-init: ${status} (${elapsed}s elapsed)"
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [[ $elapsed -ge $timeout ]]; then
        log_warn "cloud-init did not finish within ${timeout}s; proceeding anyway"
    fi

    # Also wait for any apt locks to release (bounded similarly)
    local apt_elapsed=0
    while [[ $apt_elapsed -lt 300 ]]; do
        ssh_vm "fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend 2>/dev/null" >/dev/null 2>&1 || break
        sleep 5
        apt_elapsed=$((apt_elapsed + 5))
    done
}

configure_vm_ssh() {
    # Disable SSH entirely if not wanted
    if [[ "${VM_ENABLE_SSH:-true}" != "true" ]]; then
        log_info "Disabling SSH server in VM..."
        ssh_vm "systemctl disable --now ssh"
        return 0
    fi

    # Disable root login if not wanted (create a non-root user first)
    if [[ "${VM_ENABLE_ROOT_LOGIN:-true}" != "true" ]]; then
        log_info "Disabling root SSH login..."
        ssh_vm "
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
            systemctl reload ssh
        "
    fi
}

# ==============================================================================
# VM Lifecycle
# ==============================================================================

destroy_existing_vm() {
    if qm status "$VM_ID" &>/dev/null; then
        log_warn "VM ${VM_ID} already exists - destroying"
        qm unlock "$VM_ID" 2>/dev/null || true
        qm stop "$VM_ID" --skiplock 2>/dev/null || true
        sleep 3
        qm unlock "$VM_ID" 2>/dev/null || true
        qm destroy "$VM_ID" --purge
        sleep 2
    fi
}

clone_from_golden_image() {
    local storage="$1"
    local golden_id="${GOLDEN_IMAGE_TEMPLATE_ID:-9100}"

    log_info "Cloning golden image template ${golden_id} → VM ${VM_ID}..."

    if ! qm status "$golden_id" &>/dev/null; then
        log_error "Golden image template ${golden_id} not found"
        exit 1
    fi

    qm clone "$golden_id" "$VM_ID" \
        --name "$VM_NAME" \
        --full 1 \
        --storage "$storage"

    log_info "VM ${VM_ID} cloned from template ${golden_id}"
}

configure_vm_hardware() {
    log_info "Configuring VM hardware..."

    qm set "$VM_ID" \
        --memory "$VM_MEMORY" \
        --cores "$VM_CORES" \
        --cpu x86-64-v2-AES \
        --scsihw virtio-scsi-single \
        --onboot 1

    # Enable iothread and writethrough cache on scsi0
    local current_scsi0
    current_scsi0=$(qm config "$VM_ID" | grep "^scsi0:" | sed 's/^scsi0: //')
    if [[ -n "$current_scsi0" ]]; then
        # Add iothread and cache if not already present
        local new_scsi0="$current_scsi0"
        if [[ "$new_scsi0" != *"iothread=1"* ]]; then
            new_scsi0="${new_scsi0},iothread=1"
        fi
        if [[ "$new_scsi0" != *"cache="* ]]; then
            new_scsi0="${new_scsi0},cache=writethrough"
        fi
        qm set "$VM_ID" --scsi0 "$new_scsi0"
    fi

    log_info "Hardware configured: ${VM_CORES} cores, ${VM_MEMORY}MB RAM"
}

configure_vm_network() {
    log_info "Configuring VM network..."

    local net_config="virtio,bridge=${VM_BRIDGE},firewall=1"

    if [[ -n "${VM_VLAN_TAG:-}" ]]; then
        net_config="${net_config},tag=${VM_VLAN_TAG}"
    fi

    qm set "$VM_ID" --net0 "$net_config"

    log_info "Network: bridge=${VM_BRIDGE}, VLAN=${VM_VLAN_TAG:-none}"
}

resize_vm_disk() {
    local storage="$1"

    log_info "Resizing disk to ${VM_DISK}G..."
    qm disk resize "$VM_ID" scsi0 "${VM_DISK}G" 2>/dev/null || true
}

configure_cloud_init() {
    log_info "Configuring cloud-init..."

    local gateway="${VM_GATEWAY:-${GATEWAY_IP:?VM_GATEWAY or GATEWAY_IP must be set}}"
    local dns="${DNS_SERVERS:-1.1.1.1 8.8.8.8}"

    # Find SSH public key (on the Proxmox host, copied during deploy)
    local ssh_key_file=""
    if [[ -n "${VM_SSH_KEY_FILE:-}" ]] && [[ -f "$VM_SSH_KEY_FILE" ]]; then
        ssh_key_file="$VM_SSH_KEY_FILE"
    elif [[ -f "/root/.ssh/homelab_admin.pub" ]]; then
        ssh_key_file="/root/.ssh/homelab_admin.pub"
    elif [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]] && [[ -f "$SSH_PUBLIC_KEY_PATH" ]]; then
        ssh_key_file="$SSH_PUBLIC_KEY_PATH"
    fi

    qm set "$VM_ID" \
        --ciuser root \
        --cipassword "${VM_SSH_PASSWORD:-changeme}" \
        --ipconfig0 "ip=${VM_IP}/24,gw=${gateway}" \
        --nameserver "$dns"

    # Add SSH key if available (required - cloud images disable password auth for root)
    if [[ -n "$ssh_key_file" ]]; then
        qm set "$VM_ID" --sshkeys "$ssh_key_file"
        log_info "Cloud-init: IP=${VM_IP}, GW=${gateway}, SSH key loaded"
    else
        log_warn "No SSH public key found - VM may not be accessible via SSH"
        log_warn "Ensure /root/.ssh/homelab_admin.pub exists on Proxmox host"
    fi
}

# ==============================================================================
# VM Start & Wait
# ==============================================================================

start_and_wait_vm() {
    log_info "Starting VM ${VM_ID}..."
    qm start "$VM_ID"

    log_info "Waiting for VM to boot and SSH to become available..."

    local timeout=120
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ssh_vm "echo ready" &>/dev/null; then
            log_info "VM is up and SSH is ready"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_error "VM ${VM_ID} did not become reachable via SSH within ${timeout}s"
    exit 1
}

# ==============================================================================
# SSH / SCP Helpers
# ==============================================================================

ssh_vm() {
    local key_opt=""
    if [[ -f "/root/.ssh/homelab_admin" ]]; then
        key_opt="-i /root/.ssh/homelab_admin"
    fi
    ssh $key_opt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        "root@${VM_IP}" "$@"
}

scp_vm() {
    local key_opt=""
    if [[ -f "/root/.ssh/homelab_admin" ]]; then
        key_opt="-i /root/.ssh/homelab_admin"
    fi
    scp $key_opt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        "$@"
}

# ==============================================================================
# Package Installation
# ==============================================================================

install_packages_vm() {
    log_info "Installing packages: $*"
    ssh_vm "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq $* > /dev/null 2>&1"
}

# ==============================================================================
# Docker Installation
# ==============================================================================

install_docker_in_vm() {
    log_section "Installing Docker in VM ${VM_ID}"

    if ssh_vm "docker --version" &>/dev/null; then
        log_info "Docker already installed"
        return 0
    fi

    ssh_vm "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates > /dev/null 2>&1
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    " 2>&1 | tail -5

    if ssh_vm "docker --version" &>/dev/null; then
        log_info "Docker installed successfully"
    else
        log_error "Docker installation failed"
        exit 1
    fi
}

# ==============================================================================
# Portainer Agent Installation
# ==============================================================================

install_portainer_agent() {
    log_info "Installing Portainer Agent..."

    local portainer_server_ip="${PORTAINER_SERVER_IP:?PORTAINER_SERVER_IP must be set}"

    # Remove standalone Portainer if running (replaced by centralized server)
    if ssh_vm "docker ps -a --format '{{.Names}}' | grep -q '^portainer$'" 2>/dev/null; then
        log_info "Removing standalone Portainer (replaced by centralized server)..."
        ssh_vm "docker stop portainer 2>/dev/null || true && docker rm portainer 2>/dev/null || true && docker volume rm portainer_data 2>/dev/null || true"
    fi

    # Check if agent already running
    if ssh_vm "docker ps --format '{{.Names}}' | grep -q portainer_agent" 2>/dev/null; then
        log_info "Portainer Agent already running"
        return 0
    fi

    # Run agent bound to VM IP only (not 0.0.0.0)
    ssh_vm "
        docker run -d \
            --name portainer_agent \
            --restart=always \
            -p ${VM_IP}:9001:9001 \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /var/lib/docker/volumes:/var/lib/docker/volumes \
            portainer/agent:lts
    "

    # Firewall: only allow Portainer server to reach agent port
    # Must use DOCKER-USER chain - Docker-published ports bypass INPUT entirely
    ssh_vm "
        iptables -C DOCKER-USER -p tcp --dport 9001 -s ${portainer_server_ip} -j RETURN 2>/dev/null || \
            iptables -I DOCKER-USER -p tcp --dport 9001 -s ${portainer_server_ip} -j RETURN
        iptables -C DOCKER-USER -p tcp --dport 9001 -j DROP 2>/dev/null || \
            iptables -A DOCKER-USER -p tcp --dport 9001 -j DROP
    "

    log_info "Portainer Agent installed (port 9001, locked to ${portainer_server_ip})"
}

# ==============================================================================
# Storage Mounts
# ==============================================================================

setup_nfs_mount_vm() {
    local nfs_host="$1"
    local nfs_share="$2"
    local mount_point="$3"

    log_info "Setting up NFS mount: ${nfs_host}:${nfs_share} -> ${mount_point}"

    ssh_vm "
        # Install NFS client if needed
        dpkg -l | grep -q nfs-common || {
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq nfs-common > /dev/null 2>&1
        }

        # Create mount point
        mkdir -p '${mount_point}'

        # Add to fstab if not already present
        if ! grep -q '${mount_point}' /etc/fstab; then
            echo '${nfs_host}:${nfs_share} ${mount_point} nfs vers=3,soft,timeo=60,retrans=3,_netdev 0 0' >> /etc/fstab
        fi

        # Mount
        mount '${mount_point}' 2>/dev/null || true

        # Verify
        if mountpoint -q '${mount_point}'; then
            echo 'NFS mount verified: ${mount_point}'
        else
            echo 'WARNING: NFS mount failed for ${mount_point}'
        fi
    "
}

setup_smb_mount_vm() {
    local smb_host="$1"
    local smb_share="$2"
    local mount_point="$3"
    local uid="${4:-${NAS_SMB_UID:?NAS_SMB_UID must be set in homelab.env, or pass uid as 4th arg}}"
    local gid="${5:-${NAS_SMB_UID:?NAS_SMB_UID must be set in homelab.env, or pass gid as 5th arg}}"
    local smb_user="$6"
    local smb_pass="$7"

    log_info "Setting up SMB mount: //${smb_host}/${smb_share} -> ${mount_point}"

    local creds_file="/root/.smbcredentials_${smb_share}"

    ssh_vm "
        # Install CIFS client if needed
        dpkg -l | grep -q cifs-utils || {
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq cifs-utils > /dev/null 2>&1
        }

        # Create credentials file
        cat > '${creds_file}' << CREDS
username=${smb_user}
password=${smb_pass}
CREDS
        chmod 600 '${creds_file}'

        # Create mount point
        mkdir -p '${mount_point}'

        # Add to fstab if not already present
        if ! grep -q '${mount_point}' /etc/fstab; then
            echo '//${smb_host}/${smb_share} ${mount_point} cifs credentials=${creds_file},uid=${uid},gid=${gid},file_mode=0775,dir_mode=0775,vers=3.0,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,auto 0 0' >> /etc/fstab
            systemctl daemon-reload
        fi

        # Mount
        mount '${mount_point}' 2>/dev/null || true

        # Verify
        if mountpoint -q '${mount_point}'; then
            echo 'SMB mount verified: ${mount_point}'
        else
            echo 'WARNING: SMB mount failed for ${mount_point}'
        fi
    "
}

# ==============================================================================
# File Operations
# ==============================================================================

push_files_to_vm() {
    local local_dir="$1"
    local remote_dir="$2"

    log_info "Pushing files to VM at ${remote_dir}..."
    ssh_vm "mkdir -p '${remote_dir}'"
    scp_vm -r "${local_dir}/"* "root@${VM_IP}:${remote_dir}/"
    log_info "Files pushed to ${remote_dir}"
}

# ==============================================================================
# Health Check
# ==============================================================================

wait_for_vm_port() {
    local port="$1"
    local timeout="${2:-30}"

    log_info "Waiting for service on port ${port} (timeout: ${timeout}s)..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ssh_vm "curl -sf -o /dev/null http://localhost:${port}" 2>/dev/null; then
            log_info "Service is up on port ${port}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "Service did not respond on port ${port} within ${timeout}s (may still be starting)"
}
