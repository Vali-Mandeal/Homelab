#!/bin/bash
set -e

# Bootstrap script for Jellyfin with hybrid storage (local DB + SMB backups)
# Similar architecture to ARR stack to prevent SQLite corruption

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[JELLYFIN-BOOTSTRAP]${NC} $1"; }
warn() { echo -e "${YELLOW}[JELLYFIN-BOOTSTRAP]${NC} $1"; }
error() { echo -e "${RED}[JELLYFIN-BOOTSTRAP]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[JELLYFIN-BOOTSTRAP]${NC} $1"; }

# Configuration
JELLYFIN_USER="jellyfin"

# Local storage for live databases (fast, no corruption)
JELLYFIN_DATA_LOCAL="/var/lib/jellyfin"
JELLYFIN_CONFIG_LOCAL="/etc/jellyfin"
JELLYFIN_CACHE_LOCAL="/var/cache/jellyfin"

# Mount paths + UID/GID come from /etc/jellyfin-runtime.env (written by deploy.sh)
if [[ -f /etc/jellyfin-runtime.env ]]; then
    set -a; source /etc/jellyfin-runtime.env; set +a
fi
: "${BACKUP_ROOT:?BACKUP_ROOT not set - re-run jellyfin deploy}"
: "${MEDIA_ROOT:?MEDIA_ROOT not set - re-run jellyfin deploy}"
: "${SMB_MOUNT_ROOT:?SMB_MOUNT_ROOT not set - re-run jellyfin deploy}"
: "${JELLYFIN_UID:?JELLYFIN_UID not set - re-run jellyfin deploy}"
: "${JELLYFIN_GID:?JELLYFIN_GID not set - re-run jellyfin deploy}"

BACKUP_DIR="$BACKUP_ROOT/backups"
LOG_DIR="$BACKUP_ROOT/logs"

log "Starting Jellyfin Bootstrap with Hybrid Storage"
info "Local Data: $JELLYFIN_DATA_LOCAL (live SQLite databases)"
info "Backup Location: $BACKUP_DIR (nightly backups only)"
info "Media Location: $MEDIA_ROOT (NFS mount)"

# Ensure Jellyfin is stopped (stop it if running)
ensure_jellyfin_stopped() {
    log "Ensuring Jellyfin is stopped..."
    
    if systemctl is-active --quiet jellyfin; then
        log "Jellyfin is running, stopping it now..."
        systemctl stop jellyfin
        sleep 3
        
        if systemctl is-active --quiet jellyfin; then
            error "Failed to stop Jellyfin!"
        fi
    fi
    
    log "✓ Jellyfin is stopped"
}

# Verify mounts
verify_mounts() {
    log "Verifying mounts..."
    
    # Check SMB mount
    if ! mountpoint -q $SMB_MOUNT_ROOT; then
        error "SMB mount not found at $SMB_MOUNT_ROOT"
    fi
    
    # Check NFS mount
    if ! mountpoint -q "$MEDIA_ROOT"; then
        error "Media mount not found at $MEDIA_ROOT"
    fi
    
    # Test write access to SMB mount root (before creating subdirectories)
    if ! touch $SMB_MOUNT_ROOT/.write_test 2>/dev/null; then
        error "Cannot write to SMB mount: $SMB_MOUNT_ROOT"
    fi
    rm -f $SMB_MOUNT_ROOT/.write_test
    
    log "✓ All mounts verified and writable"
}

# Setup directories
setup_directories() {
    log "Setting up directory structure..."
    
    # Create backup and log directories on SMB
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"
    chown $JELLYFIN_UID:$JELLYFIN_GID "$BACKUP_DIR" "$LOG_DIR"
    chmod 755 "$BACKUP_DIR" "$LOG_DIR"
    
    # Ensure local directories exist with proper permissions
    mkdir -p "$JELLYFIN_DATA_LOCAL" "$JELLYFIN_CONFIG_LOCAL" "$JELLYFIN_CACHE_LOCAL"
    chown -R $JELLYFIN_UID:$JELLYFIN_GID "$JELLYFIN_DATA_LOCAL" "$JELLYFIN_CONFIG_LOCAL" "$JELLYFIN_CACHE_LOCAL"
    chmod 755 "$JELLYFIN_DATA_LOCAL" "$JELLYFIN_CONFIG_LOCAL" "$JELLYFIN_CACHE_LOCAL"
    
    # Create Jellyfin log directory (for FFmpeg transcode logs)
    mkdir -p /var/log/jellyfin
    chown -R $JELLYFIN_UID:$JELLYFIN_GID /var/log/jellyfin
    chmod 755 /var/log/jellyfin
    
    # Ensure transcode cache directory has correct permissions
    mkdir -p "$JELLYFIN_CACHE_LOCAL/transcodes"
    chown -R $JELLYFIN_UID:$JELLYFIN_GID "$JELLYFIN_CACHE_LOCAL/transcodes"
    chmod 755 "$JELLYFIN_CACHE_LOCAL/transcodes"
    
    log "✓ Directory structure created"
}

# Fix Jellyfin config permissions (the logging.default.json issue)
fix_config_permissions() {
    log "Fixing Jellyfin config permissions..."
    
    # Ensure all config files are owned by jellyfin user and writable
    if [ -d "$JELLYFIN_CONFIG_LOCAL" ]; then
        chown -R $JELLYFIN_UID:$JELLYFIN_GID "$JELLYFIN_CONFIG_LOCAL"
        # Files need to be writable by jellyfin user (664, not 644)
        find "$JELLYFIN_CONFIG_LOCAL" -type f -exec chmod 664 {} \; 2>/dev/null || true
        # Directories need execute permission
        find "$JELLYFIN_CONFIG_LOCAL" -type d -exec chmod 755 {} \; 2>/dev/null || true
    fi
    
    log "✓ Config permissions fixed"
}

# Smart restore from backups
smart_restore() {
    log "Checking for existing backups..."
    
    # Find most recent backup
    local latest_backup=$(ls -t "$BACKUP_DIR"/jellyfin_backup_*.tar.gz 2>/dev/null | head -1)
    
    if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
        info "Found backup: $(basename "$latest_backup")"
        warn "Restoring from most recent backup..."
        
        # Remove existing data to ensure clean restore
        rm -rf "$JELLYFIN_DATA_LOCAL"/*
        
        # Extract backup
        # Backups may contain both var/lib/jellyfin and etc/jellyfin
        tar -xzf "$latest_backup" -C / 2>/dev/null || {
            # Fallback: try old backup format (relative to /var/lib)
            tar -xzf "$latest_backup" -C /var/lib/ 2>/dev/null || {
                error "Failed to restore backup"
            }
        }
        
        # Fix permissions after restore
        chown -R $JELLYFIN_UID:$JELLYFIN_GID "$JELLYFIN_DATA_LOCAL"
        chown -R $JELLYFIN_UID:$JELLYFIN_GID "$JELLYFIN_CONFIG_LOCAL" 2>/dev/null || true
        
        log "✓ Backup restored successfully"
    else
        info "No backups found, starting fresh"
        info "First backup will be created by nightly-backup.sh"
    fi
}

# Setup nightly backup cron
setup_backup_cron() {
    log "Setting up nightly backup cron job..."

    # Ensure backup script exists
    if [ ! -f "/root/nightly-backup.sh" ]; then
        warn "Backup script not found at /root/nightly-backup.sh"
        warn "Make sure to deploy it separately"
        return
    fi

    # Make executable
    chmod +x /root/nightly-backup.sh

    # Remove existing Jellyfin backup cron jobs
    (crontab -l 2>/dev/null | grep -v "nightly-backup.sh") | crontab - 2>/dev/null || true

    # Add new backup at 3 AM (after ARR backups at 2 AM)
    (crontab -l 2>/dev/null; echo "0 3 * * * /root/nightly-backup.sh >> $LOG_DIR/backup_cron.log 2>&1") | crontab -

    log "✓ Nightly backup scheduled at 3 AM"
    info "Logs will be written to: $LOG_DIR/"
}

# Setup transcode auto-purge cron
# Guards against a repeat of the 2026-07-15 outage where crashed-transcode leftovers
# filled the LXC root disk and tripped Jellyfin's 2 GiB free-space startup check.
setup_transcode_purge() {
    log "Setting up transcode auto-purge cron job..."

    local transcode_dir="$JELLYFIN_CACHE_LOCAL/transcodes"
    local max_age="${TRANSCODE_MAX_AGE_DAYS:-1}"

    # Remove any prior entry so re-runs stay idempotent
    (crontab -l 2>/dev/null | grep -v "# jellyfin-transcode-purge") | crontab - 2>/dev/null || true

    # 4 AM: after nightly-backup (3 AM), before daytime playback
    (crontab -l 2>/dev/null; echo "0 4 * * * find $transcode_dir -mindepth 1 -mtime +$max_age -delete >> $LOG_DIR/transcode-purge.log 2>&1 # jellyfin-transcode-purge") | crontab -

    log "✓ Transcode purge scheduled at 4 AM (files older than ${max_age}d)"
}

# Start Jellyfin service
start_jellyfin() {
    log "Starting Jellyfin service..."
    systemctl start jellyfin
    sleep 3
    
    if systemctl is-active --quiet jellyfin; then
        log "✅ Jellyfin started successfully"
    else
        warn "⚠️  Jellyfin may not have started properly"
        systemctl status jellyfin --no-pager || true
    fi
}

# Display info
show_info() {
    echo ""
    info "================================================================"
    info "Jellyfin Bootstrap Complete!"
    info "================================================================"
    echo ""
    echo "📂 Storage Architecture:"
    echo "   Live Database:    $JELLYFIN_DATA_LOCAL (local, fast)"
    echo "   Backups:          $BACKUP_DIR (SMB, nightly)"
    echo "   Media:            $MEDIA_ROOT (NFS, read-only)"
    echo "   Logs:             $LOG_DIR"
    echo ""
    echo "🔄 Backup Schedule:"
    echo "   Frequency:        Nightly at 3:00 AM"
    echo "   Retention:        7 days"
    echo "   Script:           /root/nightly-backup.sh"
    echo ""
    echo "🎬 Jellyfin Status:"
    echo "   Service:          Running"
    echo "   Web UI:           http://$(hostname -I | awk '{print $1}'):8096"
    echo ""
    warn "⚠️  IMPORTANT: SQLite databases run on LOCAL storage only!"
    warn "    Backups are stored on SMB for disaster recovery."
    warn "    This prevents corruption from network mount issues."
}

# Main execution
main() {
    ensure_jellyfin_stopped
    verify_mounts
    setup_directories
    fix_config_permissions
    smart_restore
    setup_backup_cron
    setup_transcode_purge
    start_jellyfin
    show_info
}

# Run
main "$@"
