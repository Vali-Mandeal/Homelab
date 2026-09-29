#!/usr/bin/env bash
# ==============================================================================
# Common Utilities for Service Deployment
# ==============================================================================
# Shared logging, colors, and helper functions
# Source this file from deploy scripts: source "$(dirname "$0")/lib/common.sh"
# ==============================================================================

# ==============================================================================
# Colors
# ==============================================================================

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_DIM='\033[2m'
readonly COLOR_NC='\033[0m'

# ==============================================================================
# Logging
# ==============================================================================

log_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_NC} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $1"
}

log_section() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
    echo ""
}

# ==============================================================================
# Display
# ==============================================================================

display_banner() {
    local title="$1"
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║          ${title}$(printf '%*s' $((39 - ${#title})) '')║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

# ==============================================================================
# Source Fetching
# ==============================================================================
# fetch_service_source <repo_url> <ref> <dest_dir>
#
# Downloads a GitHub repo tarball at the given ref and extracts it into
# dest_dir, flattening the top-level <repo>-<ref>/ directory. Idempotent:
# wipes dest_dir first.
#
# Used when a service's application code lives in its own GitHub repo,
# separate from this IaC tree. Set SERVICE_REPO_URL / SERVICE_REPO_REF in
# the service's config.env, then call this from the service's deploy.sh /
# update.sh before any tar-and-push step.
# ==============================================================================

fetch_service_source() {
    local repo_url="$1"
    local ref="${2:-main}"
    local dest_dir="$3"

    if [[ -z "$repo_url" || -z "$dest_dir" ]]; then
        log_error "fetch_service_source: repo_url and dest_dir required"
        return 1
    fi

    # Normalise https://github.com/OWNER/REPO[.git] → OWNER/REPO
    local owner_repo
    owner_repo="$(echo "$repo_url" | sed -E 's|^https?://github\.com/||; s|\.git$||; s|/$||')"

    local tarball_url="https://codeload.github.com/${owner_repo}/tar.gz/${ref}"
    local tmp_tar
    tmp_tar="$(mktemp)"

    log_info "Fetching ${owner_repo}@${ref}"
    if ! curl -fsSL -o "$tmp_tar" "$tarball_url"; then
        log_error "Failed to download ${tarball_url}"
        rm -f "$tmp_tar"
        return 1
    fi

    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"
    tar -xzf "$tmp_tar" -C "$dest_dir" --strip-components=1
    rm -f "$tmp_tar"

    log_info "Source ready at ${dest_dir}"
}

# ==============================================================================
# LXC config helpers (used by both native-LXC and Docker-in-LXC services)
# ==============================================================================
# Append a single line to /etc/pve/lxc/${CT_ID}.conf. Caller must have CT_ID set.
append_lxc_config() {
    local line="$1"
    local conf="/etc/pve/lxc/${CT_ID}.conf"
    echo "$line" >> "$conf"
}

# Configure UID/GID mapping so the container can write to SMB shares mounted
# with the NAS SMB UID. Idempotent: skips if any lxc.idmap line already exists.
# Requires NAS_SMB_UID (from homelab.env) and CT_ID (from the service config).
setup_uid_mapping() {
    : "${NAS_SMB_UID:?NAS_SMB_UID must be set in homelab.env}"
    : "${CT_ID:?CT_ID must be set in the service config}"

    local conf="/etc/pve/lxc/${CT_ID}.conf"
    if grep -q "^lxc\.idmap:" "$conf" 2>/dev/null; then
        log_info "UID mapping already configured for CT ${CT_ID}"
        return 0
    fi

    # Map container UIDs 0..(SMB-1) into the unprivileged host range starting
    # at 100000, passthrough container UID SMB_UID → host UID SMB_UID (so the
    # container can write to SMB shares mounted with that UID), then map the
    # remaining UIDs into the unprivileged range above the passthrough.
    local smb="$NAS_SMB_UID"
    local lo_offset=100000
    local total=65536
    local after_start=$((smb + 1))
    local after_host=$((lo_offset + smb + 1))
    local after_count=$((total - smb - 1))

    log_info "Configuring UID/GID mapping for UID ${smb} on CT ${CT_ID}..."

    append_lxc_config "lxc.idmap: u 0 ${lo_offset} ${smb}"
    append_lxc_config "lxc.idmap: g 0 ${lo_offset} ${smb}"
    append_lxc_config "lxc.idmap: u ${smb} ${smb} 1"
    append_lxc_config "lxc.idmap: g ${smb} ${smb} 1"
    append_lxc_config "lxc.idmap: u ${after_start} ${after_host} ${after_count}"
    append_lxc_config "lxc.idmap: g ${after_start} ${after_host} ${after_count}"
}

# ------------------------------------------------------------------------------
# add_pve_container_mount_dependency <host_path>
# ------------------------------------------------------------------------------
# Writes (or extends) /etc/systemd/system/pve-container@<CT_ID>.service.d/
# wait-for-nas.conf so the LXC won't start until <host_path> is mounted.
# Safe to call multiple times against the same CT for different paths - the
# second call appends to the existing RequiresMountsFor= line.
#
# Pairs with the heal-nas-mounts timer (45-heal-nas-mounts.sh on Proxmox host)
# which retries failed mounts and failed dependent services every minute.
# ------------------------------------------------------------------------------
add_pve_container_mount_dependency() {
    : "${CT_ID:?CT_ID must be set in the service config}"
    local host_path="$1"
    local dropin_dir="/etc/systemd/system/pve-container@${CT_ID}.service.d"
    local dropin_file="${dropin_dir}/wait-for-nas.conf"

    mkdir -p "$dropin_dir"

    if [[ -f "$dropin_file" ]] && grep -q "^RequiresMountsFor=" "$dropin_file" 2>/dev/null; then
        if ! grep -q "RequiresMountsFor=.*${host_path}" "$dropin_file"; then
            sed -i "s|^RequiresMountsFor=\(.*\)$|RequiresMountsFor=\1 ${host_path}|" "$dropin_file"
            log_info "Appended ${host_path} to pve-container@${CT_ID} mount dependency"
        fi
    else
        cat > "$dropin_file" <<EOF
# Block pve-container@${CT_ID}.service from starting until the NAS mount(s)
# bind-mounted into this LXC are actually active. Generated by IaC; pairs
# with the heal-nas-mounts timer that retries failed mounts every minute.
[Unit]
RequiresMountsFor=${host_path}
EOF
        log_info "Wrote ${dropin_file}"
    fi

    systemctl daemon-reload 2>/dev/null || true
}
