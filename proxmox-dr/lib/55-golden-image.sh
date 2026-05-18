#!/usr/bin/env bash
# ==============================================================================
# Golden Image Template Creation
# ==============================================================================
# Purpose: Create production golden image template from base template
# Approach: Clone template 9000 to create template 9100 on NAS storage
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

create_golden_image_template() {
    log_section "Creating Golden Image Template"

    local base_template_id="${UBUNTU_TEMPLATE_ID:-$DEFAULT_UBUNTU_TEMPLATE_ID}"
    local golden_template_id="${GOLDEN_IMAGE_TEMPLATE_ID:-$DEFAULT_GOLDEN_IMAGE_TEMPLATE_ID}"

    if check_template_exists "$golden_template_id"; then
        log_warn "Golden image template $golden_template_id already exists"
        log_info "Using existing golden image template"
        return 0
    fi

    verify_base_template_exists "$base_template_id" || return 1
    verify_nas_storage_exists || return 1
    clone_to_golden_image "$base_template_id" "$golden_template_id"

    log_info "Golden image template created successfully (ID: $golden_template_id)"
}

# ==============================================================================
# Validation Functions
# ==============================================================================

verify_base_template_exists() {
    local base_template_id="$1"

    log_info "Verifying base template $base_template_id exists..."

    if ! check_template_exists "$base_template_id"; then
        log_error "Base template $base_template_id does not exist"
        log_error "Cannot create golden image without base template"
        return 1
    fi

    log_info "✓ Base template $base_template_id found"
    return 0
}

verify_nas_storage_exists() {
    log_info "Verifying NAS storage is available..."

    if ! pvesm status | grep -q "nas-template"; then
        log_error "NAS storage 'nas-template' not found"
        log_error "Golden image requires NAS-backed storage for persistence"
        return 1
    fi

    log_info "✓ NAS storage 'nas-template' is available"
    return 0
}

# ==============================================================================
# Clone Functions
# ==============================================================================

clone_to_golden_image() {
    local base_template_id="$1"
    local golden_template_id="$2"

    log_info "Cloning template $base_template_id → $golden_template_id (full clone on NAS)..."

    qm clone "$base_template_id" "$golden_template_id" \
        --name "${UBUNTU_GOLDEN_VM_NAME}" \
        --full 1 \
        --storage "nas-template" \
        --description "Ubuntu ${UBUNTU_VERSION} LTS Golden Image - Production template for Terraform. Docker installed via Ansible post-deployment. Built: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    log_info "✓ Cloned VM $golden_template_id created on NAS storage"

    log_info "Converting VM $golden_template_id to template..."
    qm template "$golden_template_id"

    log_info "✓ Golden image template conversion complete"
}
