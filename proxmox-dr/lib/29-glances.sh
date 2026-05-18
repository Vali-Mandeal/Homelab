#!/usr/bin/env bash
# ==============================================================================
# Glances REST API Configuration
# ==============================================================================
# Install Glances and expose its REST API for Homepage dashboard monitoring
# ==============================================================================

readonly GLANCES_SERVICE_FILE="/etc/systemd/system/glances.service"
readonly GLANCES_PORT="61208"

# ==============================================================================
# Main Entry Point
# ==============================================================================

setup_glances() {
    log_section "Setting Up Glances REST API"

    install_glances
    configure_glances
    create_glances_service
    enable_glances_service

    log_info "Glances configuration complete"
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

install_glances() {
    if command -v glances &>/dev/null; then
        log_info "Glances already installed"
        return 0
    fi

    log_info "Installing Glances..."
    apt-get install -y -qq glances
}

configure_glances() {
    log_info "Configuring Glances..."
    mkdir -p /etc/glances
    cat > /etc/glances/glances.conf << 'EOF'
[fs]
allow=ext4,nfs,nfs4,cifs,smb
EOF
    log_info "Glances configured to show network mounts"
}

create_glances_service() {
    if [[ -f "$GLANCES_SERVICE_FILE" ]]; then
        log_info "Glances service already exists"
        return 0
    fi

    log_info "Creating Glances systemd service..."
    cat > "$GLANCES_SERVICE_FILE" << EOF
[Unit]
Description=Glances REST API
After=network.target

[Service]
ExecStart=/usr/bin/glances -w --disable-webui -B 0.0.0.0 -p ${GLANCES_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Glances service created"
}

enable_glances_service() {
    if systemctl is-enabled glances.service &>/dev/null; then
        log_info "Glances service already enabled"
    else
        log_info "Enabling Glances service..."
        systemctl enable glances.service
    fi

    if systemctl is-active glances.service &>/dev/null; then
        log_info "Glances service already running"
    else
        log_info "Starting Glances service..."
        systemctl start glances.service
    fi

    log_info "Glances REST API listening on port ${GLANCES_PORT}"
}
