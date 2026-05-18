#!/usr/bin/env bash
# ==============================================================================
# Network Configuration
# ==============================================================================
# Configure network bridges and VLANs for Proxmox
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

configure_network_bridges() {
    log_section "Configuring Network Bridges"

    verify_private_bridge
    configure_public_bridge
    verify_bridge_status

    log_info "Network bridge configuration complete"
}

# ==============================================================================
# Orchestrator Functions
# ==============================================================================

verify_private_bridge() {
    if grep -q "$PRIVATE_NETWORK_BRIDGE" /etc/network/interfaces 2>/dev/null; then
        log_info "Private network bridge $PRIVATE_NETWORK_BRIDGE already configured"
    else
        log_warn "Private network bridge $PRIVATE_NETWORK_BRIDGE not found - this is unusual"
    fi
}

configure_public_bridge() {
    if is_public_bridge_configured; then
        log_info "Public network bridge $PUBLIC_NETWORK_BRIDGE already configured"
        return 0
    fi

    log_info "Creating public network bridge $PUBLIC_NETWORK_BRIDGE with VLAN tag $PUBLIC_VLAN_TAG..."

    add_public_bridge_to_interfaces
    create_vlan_interface
    bring_up_public_bridge

    log_info "✓ Public network bridge $PUBLIC_NETWORK_BRIDGE created with VLAN tag $PUBLIC_VLAN_TAG"
}

verify_bridge_status() {
    if ip link show $PRIVATE_NETWORK_BRIDGE &>/dev/null; then
        log_info "✓ $PRIVATE_NETWORK_BRIDGE is active"
    fi

    if ip link show $PUBLIC_NETWORK_BRIDGE &>/dev/null; then
        log_info "✓ $PUBLIC_NETWORK_BRIDGE is active"
    fi
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

is_public_bridge_configured() {
    grep -q "^auto $PUBLIC_NETWORK_BRIDGE" /etc/network/interfaces 2>/dev/null
}

add_public_bridge_to_interfaces() {
    if [[ -n "${PROXMOX_PUBLIC_IP:-}" ]]; then
        log_info "Assigning IP ${PROXMOX_PUBLIC_IP} to ${PUBLIC_NETWORK_BRIDGE}..."
        cat >> /etc/network/interfaces <<EOF

auto $PUBLIC_NETWORK_BRIDGE
iface $PUBLIC_NETWORK_BRIDGE inet static
	address ${PROXMOX_PUBLIC_IP}/24
	bridge-ports vmbr0.$PUBLIC_VLAN_TAG
	bridge-stp off
	bridge-fd 0
#Public network bridge on VLAN $PUBLIC_VLAN_TAG
EOF
    else
        cat >> /etc/network/interfaces <<EOF

auto $PUBLIC_NETWORK_BRIDGE
iface $PUBLIC_NETWORK_BRIDGE inet manual
	bridge-ports vmbr0.$PUBLIC_VLAN_TAG
	bridge-stp off
	bridge-fd 0
#Public network bridge on VLAN $PUBLIC_VLAN_TAG
EOF
    fi
}

create_vlan_interface() {
    if ! ip link show vmbr0.$PUBLIC_VLAN_TAG &>/dev/null; then
        log_info "Creating VLAN interface vmbr0.$PUBLIC_VLAN_TAG..."
        ip link add link vmbr0 name vmbr0.$PUBLIC_VLAN_TAG type vlan id $PUBLIC_VLAN_TAG
        ip link set dev vmbr0.$PUBLIC_VLAN_TAG up
    fi
}

bring_up_public_bridge() {
    ifup $PUBLIC_NETWORK_BRIDGE 2>/dev/null || {
        log_warn "Failed to bring up $PUBLIC_NETWORK_BRIDGE immediately - it will be available after reboot"
    }
}
