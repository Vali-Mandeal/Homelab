#!/usr/bin/env bash
# ==============================================================================
# Shared LXC Service Functions (bare metal, no Docker)
# ==============================================================================
# Common functions for deploying services directly inside LXC containers.
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

create_lxc() {
    log_section "Creating LXC Container: ${CT_NAME} (${CT_ID})"

    # Refresh mode: skip destroy+create, just ensure existing container is running
    if [[ "${DEPLOY_MODE:-full}" == "refresh" ]]; then
        if reuse_existing_lxc; then
            return 0
        fi
        log_warn "Falling back to full create"
    fi

    local storage="${CT_STORAGE:-local-lvm}"
    local template
    template=$(select_lxc_template)

    destroy_existing_container
    create_base_container "$template" "$storage"
    start_and_wait
    set_static_ip

    log_info "Container ${CT_NAME} (${CT_ID}) ready at ${CT_IP}"
}

# Returns 0 if existing container was successfully reused, non-zero otherwise.
reuse_existing_lxc() {
    if ! pct status "$CT_ID" &>/dev/null; then
        log_warn "Refresh requested but container ${CT_ID} doesn't exist"
        return 1
    fi

    log_info "Refresh mode: reusing existing container ${CT_ID}"

    pct start "$CT_ID" 2>/dev/null || true

    local retries=15
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CT_ID" -- echo ready &>/dev/null; then
            log_info "Container ${CT_NAME} (${CT_ID}) ready at ${CT_IP}"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done

    log_warn "Container ${CT_ID} exists but did not respond"
    return 1
}

# ==============================================================================
# Template Selection (shared with docker-service.sh)
# ==============================================================================

select_lxc_template() {
    local template

    template=$(pveam list local 2>/dev/null | grep -E "ubuntu.*standard" | sort -V | tail -1 | awk '{print $1}')

    if [[ -z "$template" ]]; then
        template=$(pveam list local 2>/dev/null | grep -E "debian.*standard" | sort -V | tail -1 | awk '{print $1}')
    fi

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

create_base_container() {
    local template="$1"
    local storage="$2"

    log_info "Creating container ${CT_ID}..."

    local net_config="name=eth0,bridge=${CT_BRIDGE},firewall=1,ip=dhcp"

    pct create "$CT_ID" "$template" \
        --hostname "$CT_NAME" \
        --memory "$CT_MEMORY" \
        --cores "$CT_CORES" \
        --rootfs "${storage}:${CT_DISK}" \
        --net0 "$net_config" \
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1
}

start_and_wait() {
    log_info "Starting container ${CT_ID}..."
    pct start "$CT_ID"
    sleep 3

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

    pct stop "$CT_ID"
    sleep 2
    pct start "$CT_ID"
    sleep 3

    local actual_ip
    actual_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [[ "$actual_ip" == "$CT_IP" ]]; then
        log_info "IP verified: ${CT_IP}"
    else
        log_warn "Expected IP ${CT_IP}, got ${actual_ip:-none} - may need a moment to settle"
    fi
}

# ==============================================================================
# LXC Config Helpers
# ==============================================================================

# append_lxc_config + setup_uid_mapping moved to common.sh (shared by both
# this library and docker-service.sh).

setup_bind_mount() {
    local host_path="$1"
    local container_path="$2"

    log_info "Bind mount: ${host_path} -> /${container_path}"
    # Trigger systemd-automount on the host path before binding - bind alone
    # does not fire autofs, so without this the LXC sees the empty stub if
    # the NAS mount hadn't been accessed yet (e.g. fresh boot).
    append_lxc_config "lxc.hook.pre-start: sh -c 'ls ${host_path} >/dev/null 2>&1 || true'"
    append_lxc_config "lxc.mount.entry: ${host_path} ${container_path} none bind,optional,create=dir 0 0"

    # Make pve-container@<CT>.service block on the host mount being live, so
    # the bind can't establish onto an empty pre-mount stub at boot. The
    # heal-nas-mounts timer handles recovering from any failed-at-boot mounts.
    add_pve_container_mount_dependency "$host_path"
}

setup_gpu_passthrough() {
    log_info "Configuring iGPU passthrough..."

    local render_gid
    render_gid=$(getent group render | cut -d: -f3)

    if [[ -z "$render_gid" ]]; then
        log_warn "Render group not found - skipping GPU passthrough"
        return 1
    fi

    log_info "Using render group GID: ${render_gid}"

    append_lxc_config "lxc.cgroup2.devices.allow: c 226:128 rwm"
    append_lxc_config "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file"
    append_lxc_config "lxc.hook.pre-start: sh -c 'chown 100000:\$(($render_gid + 100000)) /dev/dri/renderD128'"
}

# ==============================================================================
# Package Installation
# ==============================================================================

install_packages() {
    log_info "Installing packages: $*"
    pct exec "$CT_ID" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq $* > /dev/null 2>&1
    "
}

# ==============================================================================
# File Operations
# ==============================================================================

push_file() {
    local src="$1"
    local dest="$2"
    pct push "$CT_ID" "$src" "$dest"
}

exec_in_ct() {
    pct exec "$CT_ID" -- "$@"
}

# ==============================================================================
# Health Check
# ==============================================================================

wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"

    log_info "Waiting for port ${port} (timeout: ${timeout}s)..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if pct exec "$CT_ID" -- bash -c "curl -sf -o /dev/null http://localhost:${port}" 2>/dev/null; then
            log_info "Service is up on port ${port}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "Service did not respond on port ${port} within ${timeout}s"
}
