#!/usr/bin/env bash
# ==============================================================================
# Shared Docker-in-LXC Service Functions
# ==============================================================================
# Common functions for deploying Docker services inside LXC containers.
# Runs ON Proxmox. Sourced by individual service deploy scripts.
#
# Required variables (set by service config.env before calling):
#   CT_ID, CT_NAME, CT_IP, CT_MEMORY, CT_CORES, CT_DISK, CT_BRIDGE
# Optional:
#   CT_VLAN_TAG, CT_STORAGE (defaults to local-lvm)
# ==============================================================================

# ==============================================================================
# LXC Container Creation
# ==============================================================================

create_docker_lxc() {
    log_section "Creating LXC Container: ${CT_NAME} (${CT_ID})"

    # Refresh mode: skip destroy+create, just ensure existing container is running
    if [[ "${DEPLOY_MODE:-full}" == "refresh" ]]; then
        if reuse_existing_docker_lxc; then
            return 0
        fi
        log_warn "Falling back to full create"
    fi

    local storage="${CT_STORAGE:-local-lvm}"
    local template
    template=$(select_lxc_template)

    destroy_existing_container
    create_container "$template" "$storage"
    configure_container_for_docker
    start_container
    set_static_ip
    install_ssh_key
    install_docker_in_container

    log_info "Container ${CT_NAME} (${CT_ID}) ready with Docker at ${CT_IP}"
}

# Returns 0 if existing container was successfully reused, non-zero otherwise.
# Caller should fall back to full create on non-zero return.
reuse_existing_docker_lxc() {
    if ! pct status "$CT_ID" &>/dev/null; then
        log_warn "Refresh requested but container ${CT_ID} doesn't exist"
        return 1
    fi

    log_info "Refresh mode: reusing existing container ${CT_ID}"

    # Start if not already running (pct start is a no-op if already running)
    pct start "$CT_ID" 2>/dev/null || true

    # Wait for container to respond
    local retries=15
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CT_ID" -- echo ready &>/dev/null; then
            # Sanity check: Docker should be present in a Docker-in-LXC container
            if ! pct exec "$CT_ID" -- docker --version &>/dev/null; then
                log_warn "Container ${CT_ID} exists but Docker is not installed"
                return 1
            fi
            log_info "Container ${CT_NAME} (${CT_ID}) ready with Docker at ${CT_IP}"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done

    log_warn "Container ${CT_ID} exists but did not respond"
    return 1
}

# ==============================================================================
# Template Selection
# ==============================================================================

select_lxc_template() {
    local template

    # Try locally available templates: prefer Ubuntu, fall back to Debian
    template=$(pveam list local 2>/dev/null | grep -E "ubuntu.*standard" | sort -V | tail -1 | awk '{print $1}')

    if [[ -z "$template" ]]; then
        template=$(pveam list local 2>/dev/null | grep -E "debian.*standard" | sort -V | tail -1 | awk '{print $1}')
    fi

    # Nothing local - download the latest available from Proxmox repos
    if [[ -z "$template" ]]; then
        log_info "No local templates - downloading latest Ubuntu template..." >&2
        pveam update >/dev/null 2>&1 || true

        local remote_tpl
        remote_tpl=$(pveam available --section system 2>/dev/null | grep -E "ubuntu.*standard" | sort -V | tail -1 | awk '{print $1}')

        if [[ -z "$remote_tpl" ]]; then
            remote_tpl=$(pveam available --section system 2>/dev/null | grep -E "debian.*standard" | sort -V | tail -1 | awk '{print $1}')
        fi

        if [[ -z "$remote_tpl" ]]; then
            log_error "No suitable LXC template found locally or in Proxmox repos" >&2
            exit 1
        fi

        log_info "Downloading template: ${remote_tpl}..." >&2
        pveam download local "$remote_tpl"

        template="local:vztmpl/${remote_tpl}"
    fi

    # All log messages go to stderr so they don't pollute the return value
    log_info "Using template: $template" >&2
    echo "$template"
}

# ==============================================================================
# Container Lifecycle
# ==============================================================================

destroy_existing_container() {
    if pct status "$CT_ID" &>/dev/null; then
        log_warn "Container ${CT_ID} already exists - destroying"
        pct stop "$CT_ID" 2>/dev/null || true
        sleep 2
        pct destroy "$CT_ID" --force 2>/dev/null || true
        sleep 1
    fi
}

create_container() {
    local template="$1"
    local storage="$2"

    log_info "Creating container ${CT_ID}..."
    pct create "$CT_ID" "$template" \
        --hostname "$CT_NAME" \
        --memory "$CT_MEMORY" \
        --cores "$CT_CORES" \
        --rootfs "${storage}:${CT_DISK}" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},firewall=1,ip=dhcp" \
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1
}

configure_container_for_docker() {
    log_info "Configuring container for Docker..."

    local conf="/etc/pve/lxc/${CT_ID}.conf"

    # Required for Docker-in-LXC
    echo "lxc.apparmor.profile: unconfined" >> "$conf"
    echo "lxc.cap.drop:" >> "$conf"
    echo "lxc.mount.auto: sys:rw" >> "$conf"

    # Hide AppArmor from Docker - prevents build failures in LXC
    # (Docker detects AppArmor as available but can't apply profiles)
    echo "lxc.mount.entry: /dev/null sys/module/apparmor/parameters/enabled none bind 0 0" >> "$conf"
}

start_container() {
    log_info "Starting container ${CT_ID}..."
    pct start "$CT_ID"
    sleep 3

    # Wait for container to be fully up
    local retries=10
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CT_ID" -- echo "ready" &>/dev/null; then
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done

    log_error "Container ${CT_ID} failed to start"
    exit 1
}

# ==============================================================================
# Network Configuration
# ==============================================================================

set_static_ip() {
    if [[ -z "${CT_IP:-}" ]]; then
        log_warn "No static IP configured - keeping DHCP"
        return 0
    fi

    log_info "Setting static IP: ${CT_IP}"

    local gateway="${GATEWAY_IP:?GATEWAY_IP must be set in homelab.env}"
    local bridge="${CT_BRIDGE:-vmbr0}"
    local net_config="name=eth0,bridge=${bridge},firewall=1,ip=${CT_IP}/24,gw=${gateway}"

    if [[ -n "${CT_VLAN_TAG:-}" ]]; then
        net_config="${net_config},tag=${CT_VLAN_TAG}"
    fi

    pct set "$CT_ID" --net0 "$net_config"

    # Restart to apply
    pct stop "$CT_ID"
    sleep 3
    pct start "$CT_ID"

    # Wait for container to finish booting before trying to attach
    # Ubuntu LXC can take 20-30s on first boot; pct exec fails with
    # "Cannot allocate memory" if called too early (lxc-attach race condition).
    log_info "Waiting for container to boot..."
    local timeout=60
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
        local actual_ip
        actual_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [[ "$actual_ip" == "$CT_IP" ]]; then
            log_info "IP verified: ${CT_IP} (after ${elapsed}s)"
            return 0
        fi
        log_info "  ...waiting for IP (${elapsed}s/${timeout}s)"
    done

    log_warn "IP not confirmed after ${timeout}s - container may still be booting, continuing anyway"
}

# ==============================================================================
# SSH Key Installation
# ==============================================================================

install_ssh_key() {
    local key_path="${SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/homelab_admin.pub}"

    if [[ ! -f "$key_path" ]]; then
        log_warn "SSH public key not found at ${key_path} - skipping"
        return 0
    fi

    log_info "Installing SSH public key..."
    local pubkey
    pubkey=$(cat "$key_path")

    pct exec "$CT_ID" -- bash -c "
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        echo '${pubkey}' >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    "
    log_info "SSH key installed"
}

# ==============================================================================
# Docker Installation
# ==============================================================================

install_docker_in_container() {
    log_section "Installing Docker in Container ${CT_ID}"

    # Check if already installed
    if pct exec "$CT_ID" -- docker --version &>/dev/null; then
        log_info "Docker already installed"
        return 0
    fi

    # Force IPv4 for apt - avoids 2-min-per-repo timeouts when IPv6 is broken
    # (was causing 10+ minute hangs on apt-get update with no output)
    pct exec "$CT_ID" -- bash -c 'echo '\''Acquire::ForceIPv4 "true";'\'' > /etc/apt/apt.conf.d/99force-ipv4'

    # Fix locale and install prerequisites
    pct exec "$CT_ID" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export LC_ALL=C
        export LANG=C
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates locales > /dev/null 2>&1
        sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
        locale-gen > /dev/null 2>&1
    "

    # Install Docker - stream output so the SSH connection stays alive
    # curl -4 forces IPv4 (matches apt config above)
    log_info "Installing Docker (this may take a few minutes)..."
    pct exec "$CT_ID" -- bash -c "curl -4 -fsSL https://get.docker.com | sh"

    # Disable AppArmor - not functional inside unprivileged LXC, causes Docker to fail
    pct exec "$CT_ID" -- bash -c 'apt-get remove -y -qq apparmor > /dev/null 2>&1 || true'

    # Enable and start
    pct exec "$CT_ID" -- systemctl enable docker
    pct exec "$CT_ID" -- systemctl start docker

    # Verify
    if pct exec "$CT_ID" -- docker --version &>/dev/null; then
        log_info "Docker installed successfully"
    else
        log_error "Docker installation failed"
        exit 1
    fi
}

# ==============================================================================
# Bind Mounts (lxc.mount.entry - not mp0/mp1)
# ==============================================================================

setup_lxc_bind_mount() {
    local host_path="$1"
    local container_path="$2"
    local options="${3:-none bind,create=dir 0 0}"

    log_info "Bind mount: ${host_path} -> ${container_path}"

    local conf="/etc/pve/lxc/${CT_ID}.conf"

    # Check if already configured
    if grep -q "$container_path" "$conf" 2>/dev/null; then
        log_info "Bind mount already configured for ${container_path}"
        return 0
    fi

    # Stop container to modify config
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 2

    echo "lxc.mount.entry: ${host_path} ${container_path#/} ${options}" >> "$conf"

    pct start "$CT_ID"
    sleep 3
}

# ==============================================================================
# Service Deployment
# ==============================================================================

deploy_to_container() {
    local service_name="$1"
    local source_dir="$2"
    local target_dir="/opt/${service_name}"

    log_info "Deploying files to container at ${target_dir}..."

    # Create target directory
    pct exec "$CT_ID" -- mkdir -p "$target_dir"

    # Copy files using tar + pct push
    local tmp_tar="/tmp/deploy-${service_name}-$$.tar.gz"
    tar -czf "$tmp_tar" -C "$source_dir" .
    pct push "$CT_ID" "$tmp_tar" "/tmp/deploy.tar.gz"
    pct exec "$CT_ID" -- bash -c "cd '${target_dir}' && tar -xzf /tmp/deploy.tar.gz && rm /tmp/deploy.tar.gz"
    rm -f "$tmp_tar"

    log_info "Files deployed to ${target_dir}"
}

run_compose_in_container() {
    local service_name="$1"
    local target_dir="/opt/${service_name}"

    log_info "Starting Docker Compose..."
    pct exec "$CT_ID" -- bash -c "cd '${target_dir}' && docker compose up -d"
}

# ==============================================================================
# Health Check
# ==============================================================================

wait_for_service() {
    local port="$1"
    local timeout="${2:-30}"
    local host="${CT_IP}"

    log_info "Waiting for service on ${host}:${port} (timeout: ${timeout}s)..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        # No --fail/-f: this checks that the HTTP listener is up, not that the
        # app considers itself healthy. The .NET API returns 404 on `/` because
        # it has no root route; with -f curl would treat that as "not ready"
        # and we'd loop until timeout even though the service is fully alive.
        # --max-time caps a single attempt so a slow response can't stall the
        # loop past the requested timeout window.
        if pct exec "$CT_ID" -- bash -c "curl -s -o /dev/null --max-time 5 http://localhost:${port}" 2>/dev/null; then
            log_info "Service is up on port ${port}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Service did not respond on port ${port} within ${timeout}s"
    return 1
}

# ==============================================================================
# Portainer Agent Installation
# ==============================================================================

install_portainer_agent_in_container() {
    log_info "Installing Portainer Agent in container ${CT_ID}..."

    if pct exec "$CT_ID" -- docker ps --format '{{.Names}}' 2>/dev/null | grep -q portainer_agent; then
        log_info "Portainer Agent already running"
        return 0
    fi

    pct exec "$CT_ID" -- docker run -d \
        --name portainer_agent \
        --restart=always \
        --security-opt apparmor:unconfined \
        -p 9001:9001 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /var/lib/docker/volumes:/var/lib/docker/volumes \
        portainer/agent:lts

    log_info "Portainer Agent installed in ${CT_NAME}"
}
