#!/usr/bin/env bash
# ==============================================================================
# Wake-on-LAN Configuration
# ==============================================================================
# Enable or disable Wake-on-LAN for remote power management
# Controlled by WOL_ENABLED environment variable (default: false)
# ==============================================================================

# Default to disabled if not set
WOL_ENABLED="${WOL_ENABLED:-false}"

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_wake_on_lan() {
    log_section "Configuring Wake-on-LAN"

    local interface
    interface=$(detect_physical_interface)

    if [[ -z "$interface" ]]; then
        log_warn "No physical ethernet interface found"
        log_warn "Available interfaces:"
        ip link show | grep -E '^[0-9]+:' | cut -d: -f2 | tr -d ' ' | while read -r iface; do
            log_warn "  - $iface"
        done
        return 0
    fi

    log_info "Detected physical interface: $interface"

    # Check current WOL state
    local current_state
    current_state=$(get_wol_state "$interface")

    if [[ "$WOL_ENABLED" == "true" ]]; then
        log_info "WOL_ENABLED=true - Wake-on-LAN will be enabled"
        if [[ "$current_state" == "enabled" ]]; then
            log_info "✓ Wake-on-LAN already enabled on $interface - no changes needed"
            display_wol_info "$interface"
        else
            install_ethtool
            enable_wol "$interface"
            display_wol_info "$interface"
        fi
    else
        log_info "WOL_ENABLED=false - Wake-on-LAN will be disabled"
        if [[ "$current_state" == "disabled" ]]; then
            log_info "✓ Wake-on-LAN already disabled on $interface - no changes needed"
        else
            install_ethtool
            disable_wol "$interface"
        fi
    fi

    log_info "Wake-on-LAN configuration complete"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

install_ethtool() {
    if command -v ethtool &>/dev/null; then
        log_info "ethtool already installed"
        return 0
    fi

    log_info "Installing ethtool..."
    apt-get install -y ethtool
}

detect_physical_interface() {
    ip link show | grep -E '^[0-9]+: (enp|eth|ens)' | head -n1 | cut -d: -f2 | tr -d ' '
}

get_wol_state() {
    local interface="$1"
    local wol_setting

    # Get the 'Wake-on:' line from ethtool output
    wol_setting=$(ethtool "$interface" 2>/dev/null | grep -E '^\s*Wake-on:' | awk '{print $2}')

    if [[ -z "$wol_setting" ]]; then
        echo "unknown"
    elif [[ "$wol_setting" == "d" ]]; then
        echo "disabled"
    elif [[ "$wol_setting" == *"g"* ]]; then
        echo "enabled"
    else
        echo "partial"
    fi
}

display_wol_status() {
    local interface="$1"

    log_info "Current Wake-on-LAN status for $interface:"
    ethtool "$interface" 2>/dev/null | grep -i wake || log_warn "No Wake-on-LAN info available"
}

enable_wol() {
    local interface="$1"

    log_info "Enabling Wake-on-LAN for $interface..."
    if ethtool -s "$interface" wol g 2>/dev/null; then
        log_info "✓ Wake-on-LAN enabled (magic packet mode)"
    else
        log_warn "Failed to enable Wake-on-LAN (hardware may not support it)"
    fi
}

disable_wol() {
    local interface="$1"

    log_info "Disabling Wake-on-LAN for $interface..."
    if ethtool -s "$interface" wol d 2>/dev/null; then
        log_info "✓ Wake-on-LAN disabled"
    else
        log_warn "Failed to disable Wake-on-LAN"
    fi
}

display_wol_info() {
    local interface="$1"
    local mac_address

    mac_address=$(ip link show "$interface" | awk '/ether/ {print $2}')

    log_info "MAC address: $mac_address"
    log_info "To wake remotely: wakeonlan $mac_address"
}
