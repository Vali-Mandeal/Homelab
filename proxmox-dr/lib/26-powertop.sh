#!/usr/bin/env bash
# ==============================================================================
# PowerTOP Configuration
# ==============================================================================
# Install and configure PowerTOP for automatic power optimization
# ==============================================================================

readonly POWERTOP_SERVICE_FILE="/etc/systemd/system/powertop.service"

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_powertop() {
    log_section "Setting Up PowerTOP Auto-Tune"

    install_powertop
    create_powertop_service
    enable_powertop_service

    log_info "PowerTOP configuration complete"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

install_powertop() {
    if command -v powertop &>/dev/null; then
        log_info "PowerTOP already installed"
        return 0
    fi

    log_info "Installing PowerTOP..."
    apt-get install -y powertop
}

create_powertop_service() {
    if [[ -f "$POWERTOP_SERVICE_FILE" ]]; then
        log_info "PowerTOP service already exists"
        return 0
    fi

    log_info "Creating PowerTOP systemd service..."
    cat > "$POWERTOP_SERVICE_FILE" << 'EOF'
[Unit]
Description=PowerTOP auto-tune

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "PowerTOP service created"
}

enable_powertop_service() {
    if systemctl is-enabled powertop.service &>/dev/null; then
        log_info "PowerTOP service already enabled"
    else
        log_info "Enabling PowerTOP service..."
        systemctl enable powertop.service
    fi

    if systemctl is-active powertop.service &>/dev/null; then
        log_info "PowerTOP service already running"
    else
        log_info "Starting PowerTOP service..."
        systemctl start powertop.service
    fi

    log_info "✓ PowerTOP auto-tune active"
}
