#!/usr/bin/env bash
# ==============================================================================
# Homepage Dashboard - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC container, installs Docker, deploys Homepage.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/docker-service.sh"
source "${SCRIPT_DIR}/push-config.sh"

# Load shared homelab config
if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

# Load service-specific config
source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Homepage Dashboard"

    create_docker_lxc
    deploy_homepage_files
    generate_custom_css
    start_homepage
    install_portainer_agent_in_container
    print_homepage_summary
}

# ==============================================================================
# Homepage-Specific Deployment
# ==============================================================================

deploy_homepage_files() {
    log_section "Deploying Homepage Configuration"

    local target="/opt/homepage"

    pct exec "$CT_ID" -- mkdir -p "${target}/config" "${target}/images"

    # Copy docker-compose.yml
    copy_file_to_container "${SCRIPT_DIR}/docker-compose.yml" "${target}/docker-compose.yml"

    # Copy config YAML files (services.yaml/widgets.yaml rendered via envsubst)
    push_homepage_config copy_file_to_container "$target"

    # Copy logo and wallpaper to images/ (mounted at /app/public/images in container)
    if [[ -f "${SCRIPT_DIR}/logo.jpg" ]]; then
        copy_file_to_container "${SCRIPT_DIR}/logo.jpg" "${target}/images/logo.jpg"
        log_info "Custom logo deployed"
    fi

    if [[ -f "${SCRIPT_DIR}/wallpaper.jpg" ]]; then
        copy_file_to_container "${SCRIPT_DIR}/wallpaper.jpg" "${target}/images/wallpaper.jpg"
        log_info "Custom wallpaper deployed"
    fi

    log_info "Homepage files deployed"
}

copy_file_to_container() {
    local src="$1"
    local dest="$2"

    pct push "$CT_ID" "$src" "$dest"
}

# ==============================================================================
# Custom CSS Generation
# ==============================================================================

generate_custom_css() {
    log_info "Generating custom CSS..."

    pct exec "$CT_ID" -- bash -c 'cat > /opt/homepage/config/custom.css << '\''CSSEOF'\''
/* Custom logo */
img[alt="Homepage Logo"],
.logo img,
header img[src*="logo.png"] {
    content: url("/images/logo.jpg") !important;
    max-height: 48px !important;
    width: auto !important;
}

img[src*="githubusercontent.com"] {
    display: none !important;
}

/* Custom wallpaper */
html, body, #__next, #__next > div, main,
[class*="background"], [style*="background"] {
    background-image: url("/images/wallpaper.jpg") !important;
    background-size: cover !important;
    background-position: center !important;
    background-repeat: no-repeat !important;
    background-attachment: fixed !important;
}

.main, .container {
    background: transparent !important;
}
CSSEOF'

    log_info "Custom CSS generated"
}

# ==============================================================================
# Start Service
# ==============================================================================

start_homepage() {
    log_section "Starting Homepage"

    run_compose_in_container "homepage"

    wait_for_service 3000 30
}

# ==============================================================================
# Summary
# ==============================================================================

print_homepage_summary() {
    log_section "Homepage Deployed Successfully"

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo "  Direct:     http://${CT_IP}:3000"
    echo "  Traefik:    https://homepage.${TRAEFIK_DOMAIN}"
    echo ""
    echo "  Config:     /opt/homepage/config/"
    echo "  Edit YAML files and refresh - auto-reloads, no restart needed."
    echo ""
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
