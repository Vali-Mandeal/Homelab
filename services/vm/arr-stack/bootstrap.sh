#!/bin/bash
set -e

# Bootstrap script for ARR Stack with persistent NAS storage
# This script ensures proper directory structure and permissions on the NAS mount

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[BOOTSTRAP]${NC} $1"; }
warn() { echo -e "${YELLOW}[BOOTSTRAP]${NC} $1"; }
error() { echo -e "${RED}[BOOTSTRAP]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[BOOTSTRAP]${NC} $1"; }

# Source environment variables
if [ ! -f ".env" ]; then
    error ".env file not found. Please ensure you're running this from the arr directory."
fi

# Clear any existing environment variables to avoid conflicts
unset MEDIA_MOUNT CONFIG_MOUNT MEDIA_ROOT DOWNLOADS_ROOT ARR_ROOT

# Source the .env file
source .env

# Verify environment variables are set correctly
if [ -z "$MEDIA_MOUNT" ] || [ -z "$CONFIG_MOUNT" ]; then
    error "MEDIA_MOUNT and CONFIG_MOUNT not set after sourcing .env file"
fi

log "Starting ARR Stack Bootstrap with Persistent Storage"
info "Media Mount: $MEDIA_MOUNT"
info "Config Mount: $CONFIG_MOUNT"

# Check if containers are running
check_containers_stopped() {
    log "Checking if ARR containers are stopped..."

    local running_containers=$(docker ps --filter "name=radarr" --filter "name=sonarr" --filter "name=prowlarr" --filter "name=jellyseerr" --filter "name=qbittorrent" --filter "name=gluetun" --format "{{.Names}}" 2>/dev/null || true)

    if [ -n "$running_containers" ]; then
        error "ARR containers are still running! Please stop them first with 'docker compose down'
Running containers:
$running_containers

This is required to prevent database corruption during restore operations."
    fi

    log "✓ No ARR containers running (safe to proceed)"
}

# Verify NAS mounts
verify_nas_mounts() {
    log "Verifying NAS mounts..."

    # Check media mount
    if ! mountpoint -q "$MEDIA_MOUNT"; then
        error "Media mount not found at $MEDIA_MOUNT. Please ensure NFS is properly mounted."
    fi

    # Test write access to media mount
    if ! touch "$MEDIA_MOUNT/.bootstrap_test" 2>/dev/null; then
        error "No write access to media mount at $MEDIA_MOUNT"
    fi
    rm -f "$MEDIA_MOUNT/.bootstrap_test"

    # Check config mount
    if ! mountpoint -q "$CONFIG_MOUNT"; then
        error "Config mount not found at $CONFIG_MOUNT. Please ensure SMB is properly mounted."
    fi

    # Test write access to config mount
    if ! touch "$CONFIG_MOUNT/.bootstrap_test" 2>/dev/null; then
        error "No write access to config mount at $CONFIG_MOUNT"
    fi
    rm -f "$CONFIG_MOUNT/.bootstrap_test"

    log "✓ Both NAS mounts verified and writable"
}

# Verify and create missing directories if needed
verify_directories() {
    log "Verifying directory structure on NAS..."

    # Only create directories that don't exist
    info "Ensuring required directories exist..."
    mkdir -p "$MOVIES_DIR" "$SERIES_DIR"
    mkdir -p "$DL_INCOMPLETE" "$DL_COMPLETE"

    # Create backup directories for configs (on SMB) - for nightly backups only
    mkdir -p "$BACKUP_RADARR" "$BACKUP_SONARR" "$BACKUP_PROWLARR" "$BACKUP_JELLYSEERR" "$BACKUP_QBITTORRENT"

    # Create local database directories (on local storage)
    info "Creating local database directories..."
    mkdir -p "$DB_RADARR" "$DB_SONARR" "$DB_PROWLARR" "$DB_JELLYSEERR" "$DB_QBITTORRENT"
    chown $PUID:$PGID "$DB_RADARR" "$DB_SONARR" "$DB_PROWLARR" "$DB_JELLYSEERR" "$DB_QBITTORRENT"
    chmod 755 "$DB_RADARR" "$DB_SONARR" "$DB_PROWLARR" "$DB_JELLYSEERR" "$DB_QBITTORRENT"

    log "✓ Directory structure verified"
}

# Export environment variables for Docker Compose
export_env_vars() {
    log "Exporting environment variables for Docker Compose..."

    # Create a .env file for docker-compose to source
    cat > "$HOME/.arr_env" << EOF
ARR_ROOT=$ARR_ROOT
DB_RADARR=$DB_RADARR
DB_SONARR=$DB_SONARR
DB_PROWLARR=$DB_PROWLARR
DB_JELLYSEERR=$DB_JELLYSEERR
DB_QBITTORRENT=$DB_QBITTORRENT
BACKUP_RADARR=$BACKUP_RADARR
BACKUP_SONARR=$BACKUP_SONARR
BACKUP_PROWLARR=$BACKUP_PROWLARR
BACKUP_JELLYSEERR=$BACKUP_JELLYSEERR
BACKUP_QBITTORRENT=$BACKUP_QBITTORRENT
MEDIA_ROOT=$MEDIA_ROOT
MOVIES_DIR=$MOVIES_DIR
SERIES_DIR=$SERIES_DIR
DOWNLOADS_ROOT=$DOWNLOADS_ROOT
DL_COMPLETE=$DL_COMPLETE
DL_INCOMPLETE=$DL_INCOMPLETE
PUID=$PUID
PGID=$PGID
TZ=$TZ
EOF

    log "✓ Environment variables exported and saved to ~/.arr_env"
}

# Set proper permissions
set_permissions() {
    log "Setting proper permissions..."

    # Only set ownership on config directories where we need write access
    # Don't touch media files - they're read-only via NFS
    info "Setting ownership to $PUID:$PGID on config directories only"
    chown -R "$PUID:$PGID" "$ARR_ROOT" 2>/dev/null || true

    # Set appropriate permissions on config directories
    info "Setting directory permissions on config directories..."
    find "$ARR_ROOT" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$ARR_ROOT" -type f -exec chmod 644 {} \; 2>/dev/null || true

    log "✓ Permissions set correctly on config directories"
}

# Configure qBittorrent with custom password on fresh install
configure_qbittorrent_password() {
    log "Configuring qBittorrent password..."

    local qbt_config="$DB_QBITTORRENT/qBittorrent/config/qBittorrent.conf"

    # Only configure if qBittorrent.conf doesn't exist (fresh install)
    if [ ! -f "$qbt_config" ]; then
        info "Fresh qBittorrent install detected, setting up custom password..."

        # Create config directory
        mkdir -p "$(dirname "$qbt_config")"

        # Default to 'adminadmin' if QBT_PASS not set
        local qbt_pass="${QBT_PASS:-adminadmin}"

        # Create basic qBittorrent config with WebUI settings
        cat > "$qbt_config" << 'QBTCONF'
[Preferences]
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)"
QBTCONF

        chown -R $PUID:$PGID "$DB_QBITTORRENT/qBittorrent"
        chmod 644 "$qbt_config"

        warn "qBittorrent WebUI credentials set to:"
        warn "  Username: admin"
        warn "  Password: adminadmin"
        warn "  Change this immediately via Settings > Web UI after first login!"
    else
        info "qBittorrent config already exists, skipping password setup"
    fi
}

# Initialize database management and restore from backups
init_database_management() {
    log "Setting up smart database management..."

    # Smart restore: check for backups and restore if found
    smart_database_restore

    # Create logs directory on NAS for backup logs
    info "Setting up backup logging..."
    mkdir -p "$LOGS_DIR"
    chown $PUID:$PGID "$LOGS_DIR"
    chmod 755 "$LOGS_DIR"

    # Set up nightly backup cron job WITH LOGGING
    info "Setting up nightly database backup with logging..."

    # Remove any existing arr backup cron jobs
    (crontab -l 2>/dev/null | grep -v "nightly-backup.sh") | crontab - 2>/dev/null || true

    # Add new nightly backup at 2 AM - script handles its own logging with timestamps
    (crontab -l 2>/dev/null; echo "0 2 * * * cd /opt/arr && /opt/arr/nightly-backup.sh >> $LOGS_DIR/backup_cron.log 2>&1") | crontab -

    # Ensure nightly backup script is executable and has correct ownership
    if [ -f "/opt/arr/nightly-backup.sh" ]; then
        chmod +x /opt/arr/nightly-backup.sh
        chown $PUID:$PGID /opt/arr/nightly-backup.sh
    fi

    log "✓ Database management initialized with smart restore and nightly backups"
    info "Backup logs will be written to: $LOGS_DIR/backup.log"
}

# Smart database restore strategy
smart_database_restore() {
    log "Implementing smart database restore strategy..."

    # Check each app for existing backups and restore if found
    local apps=("radarr" "sonarr" "prowlarr" "jellyseerr" "qbittorrent")
    local restored_any=false

    for app in "${apps[@]}"; do
        local backup_dir_var="BACKUP_${app^^}"
        local db_dir_var="DB_${app^^}"
        local backup_dir="${!backup_dir_var}"
        local db_dir="${!db_dir_var}"

        info "Checking for $app backups..."

        # Look for the most recent backup file (format: appname_backup_TIMESTAMP.tar.gz)
        local latest_backup=""
        if [ -d "$backup_dir" ]; then
            latest_backup=$(ls -t "$backup_dir"/${app}_backup_*.tar.gz 2>/dev/null | head -1)
        fi

        if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
            info "Found backup for $app: $(basename "$latest_backup")"
            info "Restoring $app configuration from backup..."

            # Extract backup to parent of local database directory
            # The tar contains the directory itself, so extract to parent
            local parent_dir=$(dirname "$db_dir")
            tar -xzf "$latest_backup" -C "$parent_dir" 2>/dev/null || {
                warn "Failed to restore $app backup, will start fresh"
                continue
            }

            # Set proper ownership
            chown -R $PUID:$PGID "$db_dir"
            info "✓ $app configuration restored from $(basename "$latest_backup")"
            restored_any=true
        else
            info "No backup found for $app - will start fresh and create initial backup after deployment"
        fi
    done

    if [ "$restored_any" = true ]; then
        log "✓ Database restoration completed for apps with existing backups"
    else
        log "✓ No existing backups found - fresh deployment will create initial backups"
    fi
}

# Validate docker-compose setup
validate_setup() {
    log "Validating docker-compose setup..."

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose not found. Please install Docker and Docker Compose first."
    fi

    log "✓ Docker Compose configuration validated"
}

# Start ARR stack
start_arr_stack() {
    log "Starting ARR stack with Docker Compose..."

    # Source the environment variables created by bootstrap
    if [ -f ~/.arr_env ]; then
        set -a
        source ~/.arr_env
        set +a
    fi

    docker compose up -d

    log "Waiting for containers to start..."
    sleep 15

    log "✓ ARR stack started"
}

# Display service URLs
show_service_urls() {
    local vm_ip=$(hostname -I | awk '{print $1}')

    echo ""
    info "================================================================"
    info "ARR Stack Bootstrap Complete!"
    info "================================================================"
    echo ""
    echo "  Service URLs:"
    echo "    Jellyseerr:   http://$vm_ip:$JELLYSEERR_PORT"
    echo "    Prowlarr:     http://$vm_ip:9696"
    echo "    Radarr:       http://$vm_ip:7878"
    echo "    Sonarr:       http://$vm_ip:8989"
    echo "    qBittorrent:  http://$vm_ip:8080"
    echo ""
    echo "  Storage:"
    echo "    Local DBs:    $LOCAL_DB_ROOT"
    echo "    Backups:      $ARR_ROOT (SMB, nightly)"
    echo "    Media:        $MEDIA_ROOT (NFS)"
    echo ""
    echo "  Backup: Nightly at 2 AM (7-day retention)"
    echo ""
}

# Main execution
main() {
    check_containers_stopped
    verify_nas_mounts
    verify_directories
    export_env_vars
    set_permissions
    configure_qbittorrent_password
    init_database_management
    validate_setup
    start_arr_stack
    show_service_urls
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
