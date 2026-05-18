#!/usr/bin/env bash
# ==============================================================================
# VM Template Creation
# ==============================================================================
# Build Ubuntu cloud-init template for Proxmox
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

create_ubuntu_template() {
    log_section "Creating Ubuntu Cloud-Init Template"

    local template_id="${UBUNTU_TEMPLATE_ID:-$DEFAULT_UBUNTU_TEMPLATE_ID}"

    if check_template_exists "$template_id"; then
        log_warn "Template VM $template_id already exists"
        log_info "Using existing template"
        return 0
    fi

    prepare_cloud_image
    build_template_vm "$template_id"

    log_info "Ubuntu template created successfully (ID: $template_id)"
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

prepare_cloud_image() {
    local image_file="$UBUNTU_CLOUD_IMAGE_FILE"
    download_ubuntu_cloud_image "$image_file"
}

build_template_vm() {
    local template_id="$1"
    local image_file="$UBUNTU_CLOUD_IMAGE_FILE"

    create_template_vm "$template_id"
    import_disk_to_template "$template_id" "$image_file"
    configure_template_vm "$template_id"
    convert_vm_to_template "$template_id"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

check_template_exists() {
    local template_id="$1"
    qm status "$template_id" &>/dev/null
}

download_ubuntu_cloud_image() {
    local image_file="$1"

    if [[ -f "$image_file" ]]; then
        return 0
    fi

    local image_url="${UBUNTU_CLOUD_IMAGE_URL:-$DEFAULT_UBUNTU_CLOUD_IMAGE_URL}"

    log_info "Downloading Ubuntu ${UBUNTU_VERSION} cloud image..."
    wget -q --show-progress "$image_url" -O "$image_file"
}

create_template_vm() {
    local template_id="$1"

    log_info "Creating template VM $template_id..."
    qm create "$template_id" \
        --name "${UBUNTU_TEMPLATE_VM_NAME}" \
        --memory 2048 \
        --cores 2 \
        --net0 "virtio,bridge=${PRIVATE_NETWORK_BRIDGE}"
}

import_disk_to_template() {
    local template_id="$1"
    local image_file="$2"

    log_info "Importing disk image..."
    qm importdisk "$template_id" "$image_file" "${TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}" --format qcow2
}

configure_template_vm() {
    local template_id="$1"
    local storage="${TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}"

    log_info "Configuring template..."
    qm set "$template_id" \
        --scsihw virtio-scsi-pci \
        --scsi0 "${storage}:vm-${template_id}-disk-0" \
        --ide2 "${storage}:cloudinit" \
        --boot c \
        --bootdisk scsi0 \
        --serial0 socket \
        --vga serial0 \
        --cpu x86-64-v2-AES \
        --agent enabled=1
}

convert_vm_to_template() {
    local template_id="$1"

    log_info "Converting to template..."
    qm template "$template_id"
}
