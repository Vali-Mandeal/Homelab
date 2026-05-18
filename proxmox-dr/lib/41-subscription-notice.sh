#!/usr/bin/env bash
# ==============================================================================
# Subscription Notice Removal
# ==============================================================================
# Installs pve-fake-subscription to remove the "No valid subscription" popup
# This is for homelab/non-production use only
# Source: https://github.com/Jamesits/pve-fake-subscription
# ==============================================================================

readonly PVE_FAKE_SUB_VERSION="0.0.11"
readonly PVE_FAKE_SUB_URL="https://github.com/Jamesits/pve-fake-subscription/releases/download/v${PVE_FAKE_SUB_VERSION}/pve-fake-subscription_${PVE_FAKE_SUB_VERSION}%2Bgit-1_all.deb"
readonly PVE_FAKE_SUB_DEB="/tmp/pve-fake-subscription.deb"

# ==============================================================================
# Main Entry Point
# ==============================================================================

remove_subscription_notice() {
    log_section "Removing Subscription Notice"

    if is_already_installed; then
        log_info "pve-fake-subscription already installed"
        return 0
    fi

    # Try package-based approach first
    if download_fake_subscription_package; then
        install_fake_subscription_package
        block_subscription_check
        cleanup_download
        log_info "Subscription notice removed successfully (package method)"
    else
        log_info "Subscription notice removed successfully (JavaScript patch)"
    fi

    log_info "Clear your browser cache to see the change"
}

# ==============================================================================
# Validation Functions
# ==============================================================================

is_already_installed() {
    dpkg -l pve-fake-subscription 2>/dev/null | grep -q "^ii"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

download_fake_subscription_package() {
    log_info "Downloading pve-fake-subscription v${PVE_FAKE_SUB_VERSION}..."

    if ! wget -q -O "$PVE_FAKE_SUB_DEB" "$PVE_FAKE_SUB_URL"; then
        log_warn "Failed to download pve-fake-subscription"
        log_warn "Falling back to JavaScript patch method..."
        apply_javascript_patch_fallback
        return 1  # Signal that package method failed (fallback was used)
    fi

    log_info "✓ Downloaded successfully"
    return 0
}

install_fake_subscription_package() {
    log_info "Installing pve-fake-subscription..."

    if dpkg -i "$PVE_FAKE_SUB_DEB"; then
        log_info "✓ pve-fake-subscription installed"
    else
        log_error "Failed to install pve-fake-subscription"
        return 1
    fi
}

block_subscription_check() {
    # Prevent fake keys from being checked against Proxmox servers
    if ! grep -q "shop.maurer-it.com" /etc/hosts 2>/dev/null; then
        log_info "Blocking subscription check server..."
        echo "127.0.0.1 shop.maurer-it.com" >> /etc/hosts
        log_info "✓ Subscription check blocked"
    fi
}

cleanup_download() {
    rm -f "$PVE_FAKE_SUB_DEB"
}

# ==============================================================================
# Fallback: JavaScript Patch (if package install fails)
# ==============================================================================

apply_javascript_patch_fallback() {
    local proxmox_lib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

    if [[ ! -f "$proxmox_lib" ]]; then
        log_warn "Proxmox widget toolkit not found, skipping"
        return 1
    fi

    # Check if already patched
    if grep -q "orig_cmd();" "$proxmox_lib" 2>/dev/null; then
        log_info "JavaScript already patched"
        return 0
    fi

    log_info "Applying JavaScript patch..."
    sed -Ezi.bak "s/(function ?\(orig_cmd\) \{)/\1\n\torig_cmd\(\);\n\treturn;/g" "$proxmox_lib"
    systemctl restart pveproxy.service
    log_info "✓ JavaScript patch applied"
}
