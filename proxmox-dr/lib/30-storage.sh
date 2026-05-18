#!/usr/bin/env bash
# ==============================================================================
# Storage Configuration
# ==============================================================================
# NFS and SMB/CIFS mount setup with systemd automount
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_storage_mounts() {
    log_section "Setting Up Storage Mounts (NFS + SMB)"

    install_storage_clients
    prepare_mount_infrastructure
    configure_all_mounts
    activate_automount_units
    test_mount_accessibility

    log_storage_summary
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

install_storage_clients() {
    install_nfs_client
    install_smb_client
}

prepare_mount_infrastructure() {
    create_mount_points
    create_smb_credentials_file "$SMB_PRIVATE_CREDENTIALS" "$SMB_USERNAME" "$SMB_PASSWORD"
    create_smb_credentials_file "$SMB_PUBLIC_CREDENTIALS" "$SMB_USERNAME" "$SMB_PASSWORD"
}

configure_all_mounts() {
    configure_nfs_mount
    configure_smb_mounts
}

configure_nfs_mount() {
    log_info "Configuring NFS mount..."
    add_nfs_to_fstab "$NFS_PUBLIC_MEDIA_MOUNT" "$NAS_PUBLIC_IP" "$NFS_PUBLIC_MEDIA_SHARE_NAME"
}

configure_smb_mounts() {
    log_info "Configuring SMB mount for private data..."
    add_smb_to_fstab "$SMB_PRIVATE_MOUNT" "$NAS_PRIVATE_IP" "$SMB_PRIVATE_SHARE_NAME" "$SMB_PRIVATE_CREDENTIALS"

    log_info "Configuring SMB mount for public data..."
    add_smb_to_fstab "$SMB_PUBLIC_MOUNT" "$NAS_PUBLIC_IP" "$SMB_PUBLIC_SHARE_NAME" "$SMB_PUBLIC_CREDENTIALS"
}

activate_automount_units() {
    enable_automount_units
}

log_storage_summary() {
    log_info "Storage mounts configured successfully"
    log_info "Summary:"
    log_info "  - NFS: $NFS_PUBLIC_MEDIA_MOUNT ($NFS_PUBLIC_MEDIA_SHARE_NAME)"
    log_info "  - SMB: $SMB_PRIVATE_MOUNT ($SMB_PRIVATE_SHARE_NAME)"
    log_info "  - SMB: $SMB_PUBLIC_MOUNT ($SMB_PUBLIC_SHARE_NAME)"
}

# ==============================================================================
# Package Installation
# ==============================================================================

install_nfs_client() {
    if dpkg -l | grep -q nfs-common; then
        return 0
    fi

    log_info "Installing NFS client utilities..."
    apt-get update -qq
    apt-get install -y nfs-common
}

install_smb_client() {
    if dpkg -l | grep -q cifs-utils; then
        return 0
    fi

    log_info "Installing SMB/CIFS client utilities..."
    apt-get update -qq
    apt-get install -y cifs-utils
}

# ==============================================================================
# Mount Point Management
# ==============================================================================

create_mount_points() {
    log_info "Creating mount point directories..."
    mkdir -p "$NFS_PUBLIC_MEDIA_MOUNT"
    mkdir -p "$SMB_PRIVATE_MOUNT"
    mkdir -p "$SMB_PUBLIC_MOUNT"
}

# ==============================================================================
# SMB Credentials Management
# ==============================================================================

create_smb_credentials_file() {
    local creds_file="$1"
    local username="$2"
    local password="$3"

    if [[ -f "$creds_file" ]]; then
        log_info "SMB credentials file already exists: $creds_file"
        return 0
    fi

    log_info "Creating SMB credentials file: $creds_file"
    cat > "$creds_file" << EOF
username=$username
password=$password
EOF
    chmod 600 "$creds_file"
    chown root:root "$creds_file"
}

# ==============================================================================
# NFS Fstab Configuration
# ==============================================================================

add_nfs_to_fstab() {
    local mount_point="$1"
    local nfs_host="$2"
    local nfs_share="$3"
    local nfs_path="${nfs_host}:${NFS_EXPORT_BASE:-/var/nfs/shared}/${nfs_share}"

    remove_old_fstab_entry "$mount_point"

    local nfs_options="vers=3,hard,intr,timeo=600,retrans=2,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,auto"
    local fstab_entry="${nfs_path} ${mount_point} nfs ${nfs_options} 0 0"

    echo "$fstab_entry" >> "$FSTAB_FILE"
    log_info "NFS mount added to fstab: $mount_point"
}

# ==============================================================================
# SMB Fstab Configuration
# ==============================================================================

add_smb_to_fstab() {
    local mount_point="$1"
    local smb_host="$2"
    local smb_share="$3"
    local creds_file="$4"
    local uid="${5:-${NAS_SMB_UID:?NAS_SMB_UID must be set in homelab.env, or pass uid as 5th arg}}"
    local gid="${6:-${NAS_SMB_UID:?NAS_SMB_UID must be set in homelab.env, or pass gid as 6th arg}}"
    local smb_path="//${smb_host}/${smb_share}"

    remove_old_fstab_entry "$mount_point"

    local smb_options="credentials=${creds_file},uid=${uid},gid=${gid},file_mode=0775,dir_mode=0775,vers=3.0,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,auto"
    local fstab_entry="${smb_path} ${mount_point} cifs ${smb_options} 0 0"

    echo "$fstab_entry" >> "$FSTAB_FILE"
    log_info "SMB mount added to fstab: $mount_point"
}

remove_old_fstab_entry() {
    local mount_point="$1"

    if grep -q "$mount_point" "$FSTAB_FILE"; then
        log_info "Removing old fstab entry for $mount_point"
        sed -i "\|${mount_point}|d" "$FSTAB_FILE"
    fi
}

# ==============================================================================
# Systemd Automount Activation
# ==============================================================================

enable_automount_units() {
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    log_info "Enabling systemd automount units..."

    enable_and_start_automount "$NFS_PUBLIC_MEDIA_MOUNT"
    enable_and_start_automount "$SMB_PRIVATE_MOUNT"
    enable_and_start_automount "$SMB_PUBLIC_MOUNT"

    log_info "Systemd automount units configured"
}

enable_and_start_automount() {
    local mount_point="$1"
    local automount_unit
    automount_unit=$(systemd-escape -p --suffix=automount "$mount_point")

    systemctl enable "$automount_unit" 2>/dev/null || true
    systemctl start "$automount_unit" 2>/dev/null || true
}

# ==============================================================================
# Mount Testing
# ==============================================================================

test_mount_accessibility() {
    log_info "Testing mount accessibility..."

    test_mount "$NFS_PUBLIC_MEDIA_MOUNT" "NFS public media"
    test_mount "$SMB_PRIVATE_MOUNT" "SMB private"
    test_mount "$SMB_PUBLIC_MOUNT" "SMB public"
}

test_mount() {
    local mount_point="$1"
    local mount_name="$2"

    if timeout 10 ls "$mount_point" >/dev/null 2>&1; then
        log_info "✓ $mount_name mount accessible"
    else
        log_warn "$mount_name mount not accessible (will automount when NAS is online)"
    fi
}
