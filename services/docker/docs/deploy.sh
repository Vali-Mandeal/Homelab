#!/usr/bin/env bash
# ==============================================================================
# Docs - Deploy Script
# ==============================================================================
# Runs ON Proxmox. Creates LXC, bind-mounts docs from private SMB share,
# and auto-generates one Docusaurus Docker container per documentation directory.
#
# Discovery (containers only): any subdirectory of PROXMOX_DOCS_PATH containing
# a docs/ subfolder gets a Docusaurus container. Ports are assigned alphabetically
# starting at MKDOCS_PORT_START (8001).
#
# NOTE: Traefik routing is HAND-MANAGED in services/docker/traefik/routes.yml.
# When adding/removing a docs site, also edit routes.yml (router + service blocks)
# and run update-services.sh -> traefik. This script no longer touches
# routes.yml - too many cross-script writes burned us. See print_docs_summary().
#
# Hot reload: uses Chokidar polling (SMB has no inotify support).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/../.."

# ==============================================================================
# Load Libraries and Configuration
# ==============================================================================

source "${DEPLOY_ROOT}/lib/common.sh"
source "${DEPLOY_ROOT}/lib/docker-service.sh"

if [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]]; then
    source "${DEPLOY_ROOT}/config/homelab.env"
fi

source "${SCRIPT_DIR}/config.env"

# ==============================================================================
# Main
# ==============================================================================

main() {
    display_banner "Deploying Docs"

    verify_host_mount
    create_docker_lxc
    setup_docs_mount
    setup_docusaurus_sites
    seed_nas_static_assets
    generate_compose
    deploy_compose
    start_docs
    install_portainer_agent_in_container
    print_docs_summary
}

# ==============================================================================
# Pre-flight
# ==============================================================================

verify_host_mount() {
    log_section "Verifying Host Mount"

    : "${SMB_PRIVATE_MOUNT:?SMB_PRIVATE_MOUNT must be set in homelab.env}"
    if ! mountpoint -q "${SMB_PRIVATE_MOUNT}" 2>/dev/null; then
        log_error "SMB mount not found at ${SMB_PRIVATE_MOUNT}. Run proxmox-dr first!"
        exit 1
    fi

    if [[ ! -d "${PROXMOX_DOCS_PATH}" ]]; then
        log_error "Documentation directory not found: ${PROXMOX_DOCS_PATH}"
        exit 1
    fi

    local count
    count=$(find "${PROXMOX_DOCS_PATH}" -mindepth 2 -maxdepth 2 -type d -name "docs" | wc -l)
    if [[ "$count" -eq 0 ]]; then
        log_error "No docs/ subdirectory found under ${PROXMOX_DOCS_PATH}/<name>/docs/"
        exit 1
    fi

    log_info "Found ${count} documentation site(s)"
}

# ==============================================================================
# Bind Mount
# ==============================================================================

setup_docs_mount() {
    log_section "Configuring Documentation Bind Mount"

    local conf="/etc/pve/lxc/${CT_ID}.conf"

    if grep -q "lxc.mount.entry.*mnt/docs" "$conf" 2>/dev/null; then
        log_info "Docs bind mount already configured"
        return 0
    fi

    echo "lxc.mount.entry: ${PROXMOX_DOCS_PATH} ${CONTAINER_DOCS_PATH} none bind,ro,optional,create=dir 0 0" >> "$conf"
    log_info "Bind mount configured: ${PROXMOX_DOCS_PATH} -> /${CONTAINER_DOCS_PATH}"

    pct stop "$CT_ID"
    pct start "$CT_ID"
    sleep 5
}

# ==============================================================================
# Discovery
# ==============================================================================

discover_docs() {
    find "${PROXMOX_DOCS_PATH}" -mindepth 2 -maxdepth 2 -type d -name "docs" \
        | sed 's|/docs$||' \
        | xargs -I{} basename {} \
        | sort
}

# ==============================================================================
# Docusaurus Site Setup
# ==============================================================================

setup_docusaurus_sites() {
    log_section "Setting Up Docusaurus Sites"

    local docs
    mapfile -t docs < <(discover_docs)

    # Create shared entrypoint script for all doc containers
    # watcher.js handles file polling externally - avoids the --poll flag which triggers
    # a webpack ProgressPlugin schema validation crash in Docusaurus 3.7.
    pct exec "$CT_ID" -- mkdir -p /opt/docs-sites
    printf '#!/bin/sh\nexec node /app/watcher.js\n' \
        | pct push "$CT_ID" /dev/stdin /opt/docs-sites/start.sh
    pct exec "$CT_ID" -- chmod +x /opt/docs-sites/start.sh
    log_info "Entrypoint script created: /opt/docs-sites/start.sh"

    # Upload template once as a tarball
    local template_tar
    template_tar=$(mktemp --suffix=.tar.gz)
    tar czf "$template_tar" -C "${SCRIPT_DIR}/site-template" .
    pct push "$CT_ID" "$template_tar" /tmp/site-template.tar.gz
    rm -f "$template_tar"

    for doc in "${docs[@]}"; do
        local site_dir="/opt/docs-sites/${doc}"

        log_info "Setting up Docusaurus for: ${doc}"

        # Create site directory and extract template
        pct exec "$CT_ID" -- bash -c "
            mkdir -p '${site_dir}'
            tar xzf /tmp/site-template.tar.gz -C '${site_dir}'
        "

        # Read optional site metadata from a site.env in the doc root
        local site_title site_tagline
        site_title=$(resolve_site_title "$doc")
        site_tagline=$(resolve_site_tagline "$doc")

        # Instantiate config template
        pct exec "$CT_ID" -- bash -c "
            sed \
                -e 's|__SITE_NAME__|${doc}|g' \
                -e 's|__SITE_TITLE__|${site_title}|g' \
                -e 's|__SITE_TAGLINE__|${site_tagline}|g' \
                '${site_dir}/docusaurus.config.js.tpl' > '${site_dir}/docusaurus.config.js'
            rm '${site_dir}/docusaurus.config.js.tpl'
        "

        # Install npm dependencies via Docker (no node needed on LXC)
        # Pinned to node:22-alpine - node:lts-alpine (v24) breaks webpack ProgressPlugin in Docusaurus 3.7
        log_info "Installing npm dependencies for ${doc} (this may take a moment)..."
        pct exec "$CT_ID" -- docker run --rm \
            -v "${site_dir}:/app" \
            -w /app \
            node:22-alpine \
            sh -c "npm install --prefer-offline --no-audit --no-fund --ignore-scripts 2>&1 | tail -5"

        log_info "Site ${doc} ready"
    done

    pct exec "$CT_ID" -- rm -f /tmp/site-template.tar.gz
    log_info "All Docusaurus sites configured"
}

resolve_site_title() {
    local doc="$1"
    local env_file="${PROXMOX_DOCS_PATH}/${doc}/site.env"
    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        local title
        title=$((source "$env_file" 2>/dev/null && echo "${SITE_TITLE:-}") || true)
        if [[ -n "$title" ]]; then
            echo "$title"
            return 0
        fi
    fi
    # Fallback: title-case the directory name (replace hyphens/underscores with spaces)
    echo "${doc//-/ }" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

resolve_site_tagline() {
    local doc="$1"
    local env_file="${PROXMOX_DOCS_PATH}/${doc}/site.env"
    if [[ -f "$env_file" ]]; then
        local tagline
        tagline=$((source "$env_file" 2>/dev/null && echo "${SITE_TAGLINE:-}") || true)
        if [[ -n "$tagline" ]]; then
            echo "$tagline"
            return 0
        fi
    fi
    echo "Documentation"
}

# ==============================================================================
# Seed NAS Static Assets
# ==============================================================================
# When a doc has a static/ folder on the NAS, generate_compose adds a bind
# mount that overlays /app/static - which hides the template's vendor/
# (containing the draw.io viewer JS). Seed missing template files into the
# NAS static/ so the overlay still serves them. cp -n never overwrites.

seed_nas_static_assets() {
    log_section "Seeding NAS Static Assets"

    local template_static="${SCRIPT_DIR}/site-template/static"
    if [[ ! -d "$template_static" ]]; then
        log_info "No template static/ - skipping"
        return 0
    fi

    local docs
    mapfile -t docs < <(discover_docs)

    for doc in "${docs[@]}"; do
        local nas_static="${PROXMOX_DOCS_PATH}/${doc}/static"
        if [[ -d "$nas_static" ]]; then
            cp -rn "${template_static}/." "${nas_static}/" 2>/dev/null || true
            log_info "Seeded template assets into ${doc}/static/"
        fi
    done
}

# ==============================================================================
# Compose Generation
# ==============================================================================

generate_compose() {
    log_section "Generating docker-compose.yml"

    local docs
    mapfile -t docs < <(discover_docs)

    local compose_file
    compose_file="$(mktemp)"

    cat > "$compose_file" <<'HEADER'
# Auto-generated by docs/deploy.sh - do not edit manually.
# Add a new dir with a docs/ subfolder under the documentation share and redeploy.

services:
HEADER

    local port=$MKDOCS_PORT_START
    for doc in "${docs[@]}"; do
        # static/ is optional - only mount if it exists (Docker can't create dirs on ro bind mounts)
        local static_mount=""
        if [[ -d "${PROXMOX_DOCS_PATH}/${doc}/static" ]]; then
            static_mount="      - /mnt/docs/${doc}/static:/app/static:ro"
        fi

        {
            echo ""
            echo "  ${doc}:"
            echo "    image: node:22-alpine"
            echo "    container_name: docs-${doc}"
            echo "    restart: unless-stopped"
            echo "    working_dir: /app"
            echo "    entrypoint: /start.sh"
            echo "    environment:"
            echo "      - CHOKIDAR_USEPOLLING=1"
            echo "    volumes:"
            echo "      - /opt/docs-sites/${doc}:/app"
            echo "      - /opt/docs-sites/${doc}/node_modules:/app/node_modules"
            echo "      - /mnt/docs/${doc}/docs:/app/docs:ro"
            [[ -n "$static_mount" ]] && echo "$static_mount"
            echo "      - /opt/docs-sites/start.sh:/start.sh:ro"
            echo "    ports:"
            echo "      - \"${port}:8000\""
        } >> "$compose_file"
        port=$((port + 1))
    done

    cat >> "$compose_file" <<'FOOTER'

networks:
  default:
    name: docs-net
FOOTER

    GENERATED_COMPOSE="$compose_file"
    log_info "Generated compose with ${#docs[@]} service(s): ${docs[*]}"
}

# ==============================================================================
# Deploy Compose
# ==============================================================================

deploy_compose() {
    log_section "Deploying docker-compose.yml"

    pct exec "$CT_ID" -- mkdir -p /opt/docs
    pct push "$CT_ID" "$GENERATED_COMPOSE" /opt/docs/docker-compose.yml
    rm -f "$GENERATED_COMPOSE"
    log_info "docker-compose.yml deployed"
}

# ==============================================================================
# Start
# ==============================================================================

start_docs() {
    log_section "Starting Docusaurus Containers"

    pct exec "$CT_ID" -- bash -c "cd /opt/docs && docker compose up -d"

    # Wait for first doc site (Docusaurus serves under its baseUrl, so check /<name>/)
    local first_doc
    first_doc=$(discover_docs | head -1)
    local port=$MKDOCS_PORT_START

    log_info "Waiting for ${first_doc} on port ${port}..."
    local elapsed=0
    while [[ $elapsed -lt 90 ]]; do
        if pct exec "$CT_ID" -- bash -c \
            "curl -sf -o /dev/null http://localhost:${port}/${first_doc}/" 2>/dev/null; then
            log_info "Service is up"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    log_warn "Service did not respond within 90s (Docusaurus first-build can be slow)"
}

# ==============================================================================
# Summary
# ==============================================================================

print_docs_summary() {
    log_section "Docs Deployed Successfully"

    local docs
    mapfile -t docs < <(discover_docs)

    echo "  Container:  ${CT_NAME} (CT ${CT_ID})"
    echo "  IP:         ${CT_IP}"
    echo ""
    echo "  Documentation sites (containers running on this CT):"
    local port=$MKDOCS_PORT_START
    for doc in "${docs[@]}"; do
        echo "    direct: http://${CT_IP}:${port}/${doc}/   (proxied: https://${DOCS_DOMAIN}/${doc}/ - only if Traefik route exists)"
        port=$((port + 1))
    done
    echo ""
    echo "  Hot reload: Chokidar polling every ${MKDOCS_POLLING_INTERVAL}s (SMB mount)"
    echo "  Customize:  add site.env with SITE_TITLE= and SITE_TAGLINE= in doc root"
    echo ""
    echo "  Adding a new docs site (manual, deliberate):"
    echo "    1. Drop a dir with a docs/ subfolder under ${PROXMOX_DOCS_PATH}"
    echo "    2. Re-run this deploy (refresh mode) - it will spawn a container on the next port"
    echo "    3. Add a router + service block to services/docker/traefik/routes.yml"
    echo "       (same shape as docs-dummy / docs-dummy-service)"
    echo "    4. Run update-services.sh -> traefik to push the new routes"
    echo ""

    # Sanity check: warn if a discovered docs site has no Traefik route in the
    # repo's routes.yml. The deploy script can't push routes anymore (by design),
    # but it CAN tell you when you've forgotten to add one.
    check_traefik_routes_for_docs "${docs[@]}"
}

check_traefik_routes_for_docs() {
    local routes_file="${DEPLOY_ROOT}/docker/traefik/routes.yml"
    if [[ ! -f "$routes_file" ]]; then
        # Running on Proxmox after rsync - repo file isn't here. Skip silently.
        return 0
    fi

    local missing=()
    for doc in "$@"; do
        if ! grep -q "^    docs-${doc}:" "$routes_file" 2>/dev/null; then
            missing+=("$doc")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "These docs sites have containers but NO Traefik router in routes.yml:"
        for doc in "${missing[@]}"; do
            log_warn "    - ${doc}    (https://${DOCS_DOMAIN}/${doc}/ will return 404)"
        done
        log_warn "Add the router + service blocks to services/docker/traefik/routes.yml,"
        log_warn "then run: ./update-services.sh -> traefik"
    fi
}

# ==============================================================================
# Run
# ==============================================================================

main "$@"
