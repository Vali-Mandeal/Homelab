#!/usr/bin/env bash
# ==============================================================================
# LXC UID/GID Mapping Configuration
# ==============================================================================
# Configures subordinate UID/GID ranges for unprivileged LXC containers and
# allows passthrough of the NAS SMB UID (sourced from homelab.env as
# NAS_SMB_UID) so containers can write to SMB-mounted shares.
# ==============================================================================

# Linux standard subordinate ID files and range. Not configurable per-deploy
# (these are kernel/userspace conventions, identical across Debian/Ubuntu hosts).
readonly _SUBUID_FILE="/etc/subuid"
readonly _SUBGID_FILE="/etc/subgid"
readonly _UNPRIVILEGED_RANGE_START="100000"
readonly _UNPRIVILEGED_RANGE_COUNT="65536"

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_lxc_id_mapping() {
    log_section "Configuring LXC UID/GID Mappings"

    : "${NAS_SMB_UID:?NAS_SMB_UID must be set in homelab.env}"

    backup_subid_files
    configure_subordinate_uids
    configure_subordinate_gids
    display_id_mapping_summary

    log_info "LXC subordinate UID/GID mapping configured successfully"
}

# ==============================================================================
# Backup Functions
# ==============================================================================

backup_subid_files() {
    local timestamp
    timestamp=$(date +%s)

    if [[ -f "$_SUBUID_FILE" ]]; then
        cp "$_SUBUID_FILE" "${_SUBUID_FILE}.backup.${timestamp}"
        log_info "Backed up $_SUBUID_FILE"
    fi

    if [[ -f "$_SUBGID_FILE" ]]; then
        cp "$_SUBGID_FILE" "${_SUBGID_FILE}.backup.${timestamp}"
        log_info "Backed up $_SUBGID_FILE"
    fi
}

# ==============================================================================
# UID Configuration
# ==============================================================================

configure_subordinate_uids() {
    log_info "Configuring subordinate UIDs..."

    add_subid_entry "$_SUBUID_FILE" "root" "$NAS_SMB_UID" "1"
    add_subid_entry "$_SUBUID_FILE" "root" "$_UNPRIVILEGED_RANGE_START" "$_UNPRIVILEGED_RANGE_COUNT"
}

# ==============================================================================
# GID Configuration
# ==============================================================================

configure_subordinate_gids() {
    log_info "Configuring subordinate GIDs..."

    add_subid_entry "$_SUBGID_FILE" "root" "$NAS_SMB_UID" "1"
    add_subid_entry "$_SUBGID_FILE" "root" "$_UNPRIVILEGED_RANGE_START" "$_UNPRIVILEGED_RANGE_COUNT"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

add_subid_entry() {
    local file="$1"
    local user="$2"
    local start="$3"
    local count="$4"
    local entry="${user}:${start}:${count}"

    if grep -q "^${entry}$" "$file" 2>/dev/null; then
        log_info "Entry already exists: $entry"
        return 0
    fi

    echo "$entry" >> "$file"
    log_info "Added entry: $entry"
}

# ==============================================================================
# Summary Functions
# ==============================================================================

display_id_mapping_summary() {
    log_info "Current $_SUBUID_FILE configuration:"
    cat "$_SUBUID_FILE"

    log_info "Current $_SUBGID_FILE configuration:"
    cat "$_SUBGID_FILE"

    echo ""
    log_info "This configuration allows:"
    log_info "  - Standard unprivileged LXC containers"
    log_info "  - UID $NAS_SMB_UID (NAS SMB user) to be mapped into containers"
    log_info "  - GID $NAS_SMB_UID (NAS SMB group) to be mapped into containers"
    log_info ""
    log_info "Container-specific mappings are configured in /etc/pve/lxc/<CTID>.conf"
}
