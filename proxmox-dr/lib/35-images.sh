#!/usr/bin/env bash
# ==============================================================================
# Proxmox Image & Template Storage Setup
# ==============================================================================
# Sets up NAS-backed ISO/template storage for Proxmox
# Downloads all ISOs and LXC templates to NAS (persistent across rebuilds)
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_image_storage() {
    log_section "Image & Template Storage Setup"

    setup_nas_iso_storage
    download_all_isos_to_nas
    download_lxc_templates

    log_info "Image & template storage setup complete"
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

setup_nas_iso_storage() {
    log_section "Setting Up NAS-Backed ISO & Template Storage"

    verify_nas_mount || return 1
    create_nas_directories
    configure_proxmox_iso_storage
    configure_proxmox_template_storage

    log_info "NAS-backed storage configured"
}

download_all_isos_to_nas() {
    log_section "Downloading ISOs to NAS"

    log_info "Downloading Ubuntu Server ISO (for Packer templates)..."
    download_iso_to_nas \
        "Ubuntu Server ${UBUNTU_VERSION} LTS" \
        "$UBUNTU_SERVER_ISO_FILENAME" \
        "$UBUNTU_SERVER_ISO_URL"

    log_info "Downloading Ubuntu Desktop ISO (for desktop VMs)..."
    download_iso_to_nas \
        "Ubuntu Desktop ${UBUNTU_DESKTOP_ISO_VERSION} LTS" \
        "$UBUNTU_DESKTOP_ISO_FILENAME" \
        "$UBUNTU_DESKTOP_ISO_URL"

    log_info "Downloading Debian netinst ISO..."
    download_iso_to_nas \
        "Debian ${DEBIAN_ISO_VERSION} netinst" \
        "$DEBIAN_ISO_FILENAME" \
        "$DEBIAN_ISO_URL"

    log_info "✓ All ISOs downloaded to NAS"
}

download_lxc_templates() {
    log_section "Downloading LXC Container Templates"

    update_template_database
    download_ubuntu_lxc_template
    download_debian_lxc_template

    log_info "✓ LXC templates downloaded"
}

# ==============================================================================
# NAS Storage Configuration
# ==============================================================================

verify_nas_mount() {
    if ! mountpoint -q "$SMB_PRIVATE_MOUNT"; then
        log_error "NAS private mount not available: $SMB_PRIVATE_MOUNT"
        log_error "Storage setup must complete before image setup"
        return 1
    fi
    return 0
}

create_nas_directories() {
    local nas_iso_path="${SMB_PRIVATE_MOUNT}/${NAS_ISO_DIR}"
    local nas_template_path="${SMB_PRIVATE_MOUNT}/${NAS_TEMPLATE_DIR}"

    log_info "Creating NAS directories..."
    mkdir -p "$nas_iso_path"
    mkdir -p "$nas_template_path"

    log_info "✓ NAS ISO directory: $nas_iso_path"
    log_info "✓ NAS template directory: $nas_template_path"
}

configure_proxmox_iso_storage() {
    local nas_iso_path="${SMB_PRIVATE_MOUNT}/${NAS_ISO_DIR}"

    if pvesm status | grep -q "^nas-iso"; then
        log_info "Proxmox storage 'nas-iso' already configured"
        return 0
    fi

    log_info "Adding NAS ISO storage to Proxmox..."
    pvesm add dir nas-iso \
        --path "$nas_iso_path" \
        --content iso \
        --shared 1 \
        --is_mountpoint 0 || {
        log_warn "Failed to add nas-iso storage (may already exist with different name)"
    }
}

configure_proxmox_template_storage() {
    local nas_template_path="${SMB_PRIVATE_MOUNT}/${NAS_TEMPLATE_DIR}"

    if pvesm status | grep -q "^nas-template"; then
        log_info "Proxmox storage 'nas-template' already configured"
        # Ensure it supports both LXC templates and VM images
        log_info "Updating nas-template to support VM images..."
        pvesm set nas-template --content vztmpl,images || {
            log_warn "Failed to update nas-template content types"
        }
        return 0
    fi

    log_info "Adding NAS template storage to Proxmox..."
    pvesm add dir nas-template \
        --path "$nas_template_path" \
        --content vztmpl,images \
        --shared 1 \
        --is_mountpoint 0 || {
        log_warn "Failed to add nas-template storage (may already exist with different name)"
    }
}

# ==============================================================================
# ISO Download Functions
# ==============================================================================

download_iso_to_nas() {
    local name="$1"
    local filename="$2"
    local url="$3"

    local nas_iso_path="${SMB_PRIVATE_MOUNT}/${NAS_ISO_DIR}/template/iso"
    mkdir -p "$nas_iso_path"
    local iso_file="${nas_iso_path}/${filename}"

    if validate_existing_iso "$iso_file" "$filename"; then
        return 0
    fi

    if ! download_file_with_fallback "$name" "$url" "$iso_file"; then
        return 1
    fi

    log_info "✓ $name downloaded successfully"
}

validate_existing_iso() {
    local iso_file="$1"
    local filename="$2"

    if [[ ! -f "$iso_file" ]]; then
        return 1
    fi

    local file_size
    file_size=$(stat -f%z "$iso_file" 2>/dev/null || stat -c%s "$iso_file" 2>/dev/null)

    if [[ $file_size -gt 100000000 ]]; then
        log_info "✓ ISO already exists: $filename ($(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "${file_size} bytes"))"
        return 0
    else
        log_warn "ISO file too small, re-downloading: $filename"
        rm -f "$iso_file"
        return 1
    fi
}

download_file_with_fallback() {
    local name="$1"
    local url="$2"
    local destination="$3"

    log_info "Downloading $name to NAS..."
    log_info "Source: $url"
    log_info "Destination: $destination"

    if command -v wget &> /dev/null; then
        wget --show-progress -O "$destination" "$url" || {
            log_error "Failed to download $name"
            rm -f "$destination"
            return 1
        }
    elif command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$destination" "$url" || {
            log_error "Failed to download $name"
            rm -f "$destination"
            return 1
        }
    else
        log_error "Neither wget nor curl found. Cannot download ISO."
        return 1
    fi

    return 0
}

# ==============================================================================
# LXC Template Functions
# ==============================================================================

download_ubuntu_lxc_template() {
    log_info "Downloading Ubuntu ${UBUNTU_VERSION} LTS LXC template..."

    local ubuntu_template
    ubuntu_template=$(find_latest_template "$UBUNTU_LXC_TEMPLATE_PATTERN")

    if download_template_if_needed "$ubuntu_template" "nas-template"; then
        return 0
    else
        log_warn "Ubuntu LXC template not found in repository"
        return 1
    fi
}

download_debian_lxc_template() {
    log_info "Downloading Debian ${DEBIAN_VERSION} stable LXC template..."

    local debian_template
    debian_template=$(find_latest_template "$DEBIAN_LXC_TEMPLATE_PATTERN")

    if download_template_if_needed "$debian_template" "nas-template"; then
        return 0
    else
        log_warn "Debian LXC template not found in repository"
        return 1
    fi
}

update_template_database() {
    log_info "Updating Proxmox template database..."
    pveam update || log_warn "Failed to update template database"
}

find_latest_template() {
    local pattern="$1"
    pveam available | grep -E "$pattern" | sort -V | tail -n1 | awk '{print $2}'
}

download_template_if_needed() {
    local template_name="$1"
    local storage="$2"

    if [[ -z "$template_name" ]]; then
        return 1
    fi

    if ! pveam list "$storage" | grep -q "$template_name"; then
        log_info "Downloading: $template_name"
        pveam download "$storage" "$template_name" || {
            log_warn "Failed to download template: $template_name"
            return 1
        }
    else
        log_info "✓ Template already exists: $template_name"
    fi

    return 0
}
