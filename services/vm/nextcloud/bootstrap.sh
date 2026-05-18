#!/bin/bash
set -e

# Bootstrap script for Nextcloud with PostgreSQL, Redis, and NAS storage
# Creates directories, generates passwords, restores from backups, starts services

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
    error ".env file not found. Please ensure you're running this from the nextcloud directory."
fi

source .env

# Infra IPs (TRAEFIK_CT_IP, etc.) injected by deploy.sh from homelab.env
if [ -f ".env.infra" ]; then
    source .env.infra
fi

if [ -z "$DB_POSTGRES" ] || [ -z "$DB_NEXTCLOUD" ]; then
    error "Required environment variables not set after sourcing .env file"
fi

log "Starting Nextcloud Bootstrap"
info "Backup Dir: $BACKUP_DIR"
info "Local DB Root: $LOCAL_DB_ROOT"

# ==============================================================================
# Verify SMB Mounts
# ==============================================================================

verify_mounts() {
    log "Verifying SMB mounts..."

    local mounts=("$MOUNT_PERSONAL" "$MOUNT_SHARED" "$BACKUP_DIR")
    local mount_names=("Personal files" "Shared files" "Backup storage")
    # BACKUP_DIR parent is the SMB mount root
    local check_paths=("$MOUNT_PERSONAL" "$MOUNT_SHARED" "$(dirname "$BACKUP_DIR")")

    for i in "${!check_paths[@]}"; do
        if ! mountpoint -q "${check_paths[$i]}" 2>/dev/null; then
            error "${mount_names[$i]} mount not found at ${check_paths[$i]}"
        fi
        info "  ${mount_names[$i]}: ${check_paths[$i]} ✓"
    done

    log "✓ All SMB mounts verified"
}

# ==============================================================================
# Create Directory Structure
# ==============================================================================

create_directories() {
    log "Creating directory structure..."

    # Local database directories (on VM disk)
    mkdir -p "$DB_POSTGRES" "$DB_REDIS" "$DB_NEXTCLOUD"

    # Data directory (on NAS via SMB) - user files persist across VM rebuilds
    mkdir -p "$DATA_DIR"

    # Backup directories (on SMB)
    mkdir -p "$BACKUP_DIR/backups" "$LOGS_DIR"

    log "✓ Directory structure created"
}

# ==============================================================================
# Set Permissions
# ==============================================================================

set_permissions() {
    log "Setting permissions..."

    # www-data (33:33) needs to own the Nextcloud data
    chown -R 33:33 "$DB_NEXTCLOUD"

    # PostgreSQL runs as uid 70 in alpine image
    chown -R 70:70 "$DB_POSTGRES"

    # Redis runs as uid 999 in alpine image
    chown -R 999:999 "$DB_REDIS"

    chmod 755 "$LOCAL_DB_ROOT"

    log "✓ Permissions set"
}

# ==============================================================================
# Smart Database Restore
# ==============================================================================

smart_restore() {
    log "Checking for existing backups..."

    local backup_dir="$BACKUP_DIR/backups"
    local latest_backup=""

    if [ -d "$backup_dir" ]; then
        latest_backup=$(ls -t "$backup_dir"/nextcloud_backup_*.tar.gz 2>/dev/null | head -1)
    fi

    if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
        info "Found backup: $(basename "$latest_backup")"
        info "Restoring PostgreSQL dump and Nextcloud config..."

        # Extract backup to temp dir
        local tmp_dir=$(mktemp -d)
        tar -xzf "$latest_backup" -C "$tmp_dir"

        # Restore Nextcloud config if present
        if [ -d "$tmp_dir/nextcloud-config" ]; then
            mkdir -p "$DB_NEXTCLOUD/config"
            cp -a "$tmp_dir/nextcloud-config/"* "$DB_NEXTCLOUD/config/" 2>/dev/null || true
            chown -R 33:33 "$DB_NEXTCLOUD/config"
            info "✓ Nextcloud config restored"
        fi

        # Restore custom_apps (app store installs like Talk) - without these,
        # the restored DB references enabled apps whose code doesn't exist,
        # causing "Class does not exist" errors.
        if [ -d "$tmp_dir/nextcloud-custom_apps" ]; then
            mkdir -p "$DB_NEXTCLOUD/custom_apps"
            cp -a "$tmp_dir/nextcloud-custom_apps/"* "$DB_NEXTCLOUD/custom_apps/" 2>/dev/null || true
            chown -R 33:33 "$DB_NEXTCLOUD/custom_apps"
            info "✓ Nextcloud custom_apps restored"
        fi

        # PostgreSQL will be restored after containers start
        if [ -f "$tmp_dir/nextcloud_db.sql.gz" ]; then
            cp "$tmp_dir/nextcloud_db.sql.gz" "/opt/nextcloud/restore_db.sql.gz"
            info "✓ PostgreSQL dump staged for restore"
        fi

        # Stage roles dump if present (needed to recreate oc_admin user)
        if [ -f "$tmp_dir/nextcloud_roles.sql.gz" ]; then
            cp "$tmp_dir/nextcloud_roles.sql.gz" "/opt/nextcloud/restore_roles.sql.gz"
            info "✓ PostgreSQL roles staged for restore"
        fi

        rm -rf "$tmp_dir"
        log "✓ Backup restoration prepared"
    else
        log "✓ No existing backups found - fresh deployment"
    fi
}

# ==============================================================================
# Start Docker Compose
# ==============================================================================

start_services() {
    log "Starting Nextcloud services..."

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose not found"
    fi

    # During restore: only start db + redis, NOT nextcloud.
    # The restored config.php references oc_admin (created by occ maintenance:install),
    # but that PostgreSQL role doesn't exist until restore_postgres_if_needed() runs.
    # Starting nextcloud now would flood logs with "password authentication failed
    # for user oc_admin" until the roles are restored.
    if [ -f "/opt/nextcloud/restore_db.sql.gz" ]; then
        info "DB restore staged - starting only db + redis"
        docker compose up -d db redis

        # Ensure check_data_directory_permissions is disabled in restored config
        # (modify on disk since nextcloud container isn't running)
        if ! grep -q "check_data_directory_permissions" "$DB_NEXTCLOUD/config/config.php" 2>/dev/null; then
            sed -i "s/);/  'check_data_directory_permissions' => false,\n);/" \
                "$DB_NEXTCLOUD/config/config.php"
        fi
    else
        docker compose up -d
    fi

    # Wait for PostgreSQL to be ready
    log "Waiting for PostgreSQL..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if docker exec nextcloud-db pg_isready -U "$DB_USER" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done
    if [ $retries -eq 0 ]; then
        error "PostgreSQL did not become ready"
    fi
    info "✓ PostgreSQL is ready"

    # Wait for Redis to be ready
    local retries=15
    while [ $retries -gt 0 ]; do
        if docker exec nextcloud-redis redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done
    info "✓ Redis is ready"

    # If restore is staged, stop here - restore_postgres_if_needed() will
    # restore the DB, then start the nextcloud container.
    if [ -f "/opt/nextcloud/restore_db.sql.gz" ]; then
        return 0
    fi

    # Wait for Nextcloud container to be up (Apache running)
    log "Waiting for Nextcloud container..."
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker exec nextcloud true 2>/dev/null; then
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    sleep 5  # Give Apache a moment to start

    # Check if Nextcloud needs installation
    if ! docker exec -u www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then
        log "Installing Nextcloud via occ..."

        # Clean stale user data from previous installs - without the matching DB,
        # these orphaned files cause "files already exist for this user" errors.
        docker exec nextcloud bash -c 'find /var/www/html/data -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} +'

        docker exec -u www-data nextcloud php occ maintenance:install \
            --database=pgsql \
            --database-host=db \
            --database-name=nextcloud \
            --database-user="$DB_USER" \
            --database-pass="$DB_PASSWORD" \
            --admin-user="$NEXTCLOUD_ADMIN_USER" \
            --admin-pass="$NEXTCLOUD_ADMIN_PASSWORD" \
            --data-dir=/var/www/html/data

        # Disable data directory permission check - SMB mounts use dir_mode=0775
        # which cannot be changed with chmod. Permissions are controlled by mount
        # options (uid=33/gid=33) so this check is not needed.
        docker exec nextcloud sed -i "s/);/  'check_data_directory_permissions' => false,\n);/" \
            /var/www/html/config/config.php

        log "✓ Nextcloud installed"
    else
        info "Nextcloud already installed, skipping"
    fi

    # Wait for Nextcloud to be fully ready
    log "Waiting for Nextcloud to become healthy..."
    local timeout=120
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker exec nextcloud curl -fsS http://localhost/status.php >/dev/null 2>&1; then
            log "✓ Nextcloud is healthy"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        info "  Waiting... (${elapsed}s/${timeout}s)"
    done

    if [ $elapsed -ge $timeout ]; then
        warn "Nextcloud did not become healthy within ${timeout}s (may still be initializing)"
    fi
}

# ==============================================================================
# Restore PostgreSQL (after containers are running)
# ==============================================================================

restore_postgres_if_needed() {
    if [ ! -f "/opt/nextcloud/restore_db.sql.gz" ]; then
        return 0
    fi

    log "Restoring PostgreSQL database from backup..."

    # PostgreSQL is already ready from start_services()

    # Restore roles first (recreates oc_admin user that Nextcloud uses)
    if [ -f "/opt/nextcloud/restore_roles.sql.gz" ]; then
        gunzip < /opt/nextcloud/restore_roles.sql.gz | docker exec -i nextcloud-db psql -U "$DB_USER" -d postgres >/dev/null 2>&1 || true
        rm -f /opt/nextcloud/restore_roles.sql.gz
        info "✓ PostgreSQL roles restored"
    else
        # Old backup format - no roles dump. Create the app DB user from config.php.
        # occ maintenance:install creates oc_<admin> as the actual DB user.
        local nc_dbuser nc_dbpass
        nc_dbuser=$(grep "'dbuser'" "$DB_NEXTCLOUD/config/config.php" 2>/dev/null | sed "s/.*=> *'//;s/',.*//")
        nc_dbpass=$(grep "'dbpassword'" "$DB_NEXTCLOUD/config/config.php" 2>/dev/null | sed "s/.*=> *'//;s/',.*//")
        if [ -n "$nc_dbuser" ] && [ "$nc_dbuser" != "$DB_USER" ]; then
            info "Creating DB role '$nc_dbuser' from config.php (old backup format)..."
            docker exec nextcloud-db psql -U "$DB_USER" -d postgres \
                -c "CREATE ROLE \"$nc_dbuser\" WITH LOGIN PASSWORD '$nc_dbpass';" >/dev/null 2>&1 || true
            docker exec nextcloud-db psql -U "$DB_USER" -d postgres \
                -c "ALTER ROLE \"$nc_dbuser\" CREATEDB;" >/dev/null 2>&1 || true
            info "✓ DB role '$nc_dbuser' created"
        fi
    fi

    # Drop and recreate the database
    docker exec nextcloud-db dropdb -U "$DB_USER" --if-exists nextcloud 2>/dev/null || true
    docker exec nextcloud-db createdb -U "$DB_USER" nextcloud 2>/dev/null || true

    # Restore database
    gunzip < /opt/nextcloud/restore_db.sql.gz | docker exec -i nextcloud-db psql -U "$DB_USER" -d nextcloud >/dev/null 2>&1
    rm -f /opt/nextcloud/restore_db.sql.gz

    # Disable maintenance mode in config.php BEFORE starting Nextcloud.
    # The backup was taken with maintenance mode ON, so the restored config.php
    # has 'maintenance' => true. Fix it on disk while container is still down.
    if grep -q "'maintenance' => true" "$DB_NEXTCLOUD/config/config.php" 2>/dev/null; then
        sed -i "s/'maintenance' => true/'maintenance' => false/" "$DB_NEXTCLOUD/config/config.php"
        info "✓ Maintenance mode disabled in config.php"
    fi

    # Now start Nextcloud - DB has correct roles and data, maintenance mode is off
    log "Starting Nextcloud container..."
    docker compose up -d

    # Wait for Nextcloud to be healthy
    log "Waiting for Nextcloud after DB restore..."
    local timeout=120
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker exec nextcloud curl -fsS http://localhost/status.php >/dev/null 2>&1; then
            log "✓ Nextcloud is healthy"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        info "  Waiting... (${elapsed}s/${timeout}s)"
    done

    if [ $elapsed -ge $timeout ]; then
        warn "Nextcloud did not become healthy within ${timeout}s"
    fi

    log "✓ PostgreSQL database restored"
}

# ==============================================================================
# Configure Nextcloud
# ==============================================================================

configure_nextcloud() {
    log "Configuring Nextcloud..."

    # Fix .well-known redirects behind reverse proxy (Cloudflare/Traefik terminate SSL).
    # Apache's mod_rewrite R=301 in .htaccess uses the internal HTTP scheme, producing
    # http:// redirect URLs. iOS rejects this as an HTTPS→HTTP downgrade for CalDAV/CardDAV.
    # VHost-level rewrite rules run before .htaccess and explicitly use https://.
    docker exec nextcloud bash -c 'cat > /etc/apache2/sites-enabled/000-default.conf << "APACHE_EOF"
<VirtualHost *:80>
	ServerAdmin webmaster@localhost
	DocumentRoot /var/www/html
	ErrorLog ${APACHE_LOG_DIR}/error.log
	CustomLog ${APACHE_LOG_DIR}/access.log combined
	<IfModule mod_rewrite.c>
		RewriteEngine On
		RewriteCond %{HTTP:X-Forwarded-Proto} =https
		RewriteRule ^/\.well-known/caldav$ https://%{HTTP_HOST}/remote.php/dav/ [R=301,L]
		RewriteCond %{HTTP:X-Forwarded-Proto} =https
		RewriteRule ^/\.well-known/carddav$ https://%{HTTP_HOST}/remote.php/dav/ [R=301,L]
	</IfModule>
</VirtualHost>
APACHE_EOF'
    docker exec nextcloud apache2ctl graceful
    info "✓ Apache .well-known HTTPS redirects configured"

    # Run upgrade if needed (backup may be from an older Nextcloud version)
    if docker exec -u www-data nextcloud php occ status 2>&1 | grep -q "require upgrade"; then
        log "Nextcloud upgrade required - running occ upgrade..."
        docker exec -u www-data nextcloud php occ upgrade
        log "✓ Nextcloud upgrade complete"
    fi

    # Set trusted domains
    docker exec -u www-data nextcloud php occ config:system:set trusted_domains 0 --value="localhost"
    local i=1
    for domain in $TRUSTED_DOMAINS; do
        docker exec -u www-data nextcloud php occ config:system:set trusted_domains $i --value="$domain"
        i=$((i + 1))
    done
    docker exec -u www-data nextcloud php occ config:system:set overwrite.cli.url --value="$NEXTCLOUD_URL"
    info "✓ Trusted domains configured"

    # Configure Redis in config.php
    docker exec -u www-data nextcloud php occ config:system:set redis host --value=redis
    docker exec -u www-data nextcloud php occ config:system:set redis port --value=6379 --type=integer
    docker exec -u www-data nextcloud php occ config:system:set redis password --value="$REDIS_PASSWORD"
    docker exec -u www-data nextcloud php occ config:system:set memcache.local --value='\OC\Memcache\Redis'
    docker exec -u www-data nextcloud php occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
    docker exec -u www-data nextcloud php occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
    info "✓ Redis caching configured"

    # Set background job mode to cron
    docker exec -u www-data nextcloud php occ background:cron
    info "✓ Background jobs set to cron"

    # Enable external storage app
    docker exec -u www-data nextcloud php occ app:enable files_external 2>/dev/null || true
    info "✓ External storage app enabled"

    # Configure external storage mounts (from NC_MOUNTS in .env)
    # Format: "DisplayName:container_path:user" (* = all users)
    #
    # Always recreate mounts to enforce correct permissions - backups may
    # restore old configs with different access rules.
    info "Configuring external storage mounts..."

    # Remove all existing external storage mounts (backup may have stale mount IDs
    # that break file visibility for users)
    local existing_ids
    existing_ids=$(docker exec -u www-data nextcloud php occ files_external:list --output=json 2>/dev/null | \
        jq -r '.[].mount_id' 2>/dev/null) || true
    if [ -n "$existing_ids" ]; then
        local count=0
        for mid in $existing_ids; do
            docker exec -u www-data nextcloud php occ files_external:delete --yes "$mid" 2>/dev/null || true
            count=$((count + 1))
        done
        info "Removed $count stale external mount(s)"
    fi

    # Create mounts from NC_MOUNTS
    if [[ -n "${NC_MOUNTS:-}" ]]; then
        local mount_id
        IFS=',' read -ra mount_entries <<< "$NC_MOUNTS"
        for entry in "${mount_entries[@]}"; do
            local mount_name="${entry%%:*}"
            local remaining="${entry#*:}"
            local mount_path="${remaining%%:*}"
            local mount_user="${remaining#*:}"

            mount_id=$(docker exec -u www-data nextcloud php occ files_external:create \
                "$mount_name" local null::null \
                -c "datadir=$mount_path" 2>&1 | grep -o 'id [0-9]*' | awk '{print $2}')

            if [[ ! "$mount_id" =~ ^[0-9]+$ ]]; then
                warn "Failed to create ${mount_name} mount: ${mount_id}"
                continue
            fi

            if [[ "$mount_user" != "*" ]]; then
                docker exec -u www-data nextcloud php occ files_external:applicable \
                    --add-user "$mount_user" "$mount_id"
                info "✓ ${mount_name} mount (ID: ${mount_id}, ${mount_user} only)"
            else
                info "✓ ${mount_name} mount (ID: ${mount_id}, all users)"
            fi
        done
    fi

    # Re-index files for all users (mounts were recreated with new IDs,
    # so the file cache from the backup references stale mount IDs)
    docker exec -u www-data nextcloud php occ files:scan --all 2>/dev/null || true
    info "✓ File cache rebuilt for all users"

    # Configure OnlyOffice Document Server (dedicated document editing server)
    # Remove Collabora apps (backup may restore them)
    docker exec -u www-data nextcloud php occ app:remove richdocumentscode 2>/dev/null || true
    docker exec -u www-data nextcloud php occ app:remove richdocuments 2>/dev/null || true
    # Disable AppAPI (not needed - requires Docker socket for external AI/ML apps)
    docker exec -u www-data nextcloud php occ app:disable app_api 2>/dev/null || true
    # Install and enable OnlyOffice connector
    docker exec -u www-data nextcloud php occ app:install onlyoffice 2>/dev/null || true
    docker exec -u www-data nextcloud php occ app:enable onlyoffice 2>/dev/null || true
    # Document Server URL - public HTTPS URL that browsers use to load the editor JS.
    # Unlike Collabora, OnlyOffice serves its editor JS directly to the browser,
    # so this MUST be the public URL (not internal Docker hostname).
    docker exec -u www-data nextcloud php occ config:app:set onlyoffice DocumentServerUrl --value="$ONLYOFFICE_URL/"
    # Internal Document Server URL - Nextcloud → OnlyOffice (Docker network, no internet round-trip).
    # Used for server-to-server API calls (document conversion, health checks).
    docker exec -u www-data nextcloud php occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://nextcloud-onlyoffice/"
    # Nextcloud callback URL - OnlyOffice → Nextcloud (must be public HTTPS).
    # Same limitation as Collabora: overwriteprotocol=https makes Nextcloud expect HTTPS,
    # but the container only serves HTTP. Callback must go via the public URL.
    docker exec -u www-data nextcloud php occ config:app:set onlyoffice StorageUrl --value="$NEXTCLOUD_URL/"
    # JWT secret - authenticates all requests between Nextcloud and OnlyOffice.
    # Without this, anyone who can reach the Document Server can use it.
    docker exec -u www-data nextcloud php occ config:app:set onlyoffice jwt_secret --value="$ONLYOFFICE_JWT_SECRET"
    docker exec -u www-data nextcloud php occ config:app:set onlyoffice jwt_header --value="AuthorizationJwt"
    # Allow WOPI over private networks (Docker internal communication)
    docker exec -u www-data nextcloud php occ config:system:set allow_local_remote_servers --value=true --type=boolean
    info "✓ OnlyOffice Document Server configured (at $ONLYOFFICE_URL)"

    # Install Calendar app (provides web UI; CalDAV sync works via the dav app)
    docker exec -u www-data nextcloud php occ app:install calendar 2>/dev/null || true
    docker exec -u www-data nextcloud php occ app:enable calendar 2>/dev/null || true
    info "✓ Calendar app installed"

    # Enable and enforce TOTP MFA for all users
    docker exec -u www-data nextcloud php occ app:enable twofactor_totp || true
    docker exec -u www-data nextcloud php occ twofactorauth:enforce --on
    info "✓ Two-Factor TOTP enabled and enforced"

    # Set default phone region
    docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value=RO

    # Reverse proxy: trust Traefik (read from .env / configs/nextcloud.env)
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value="${TRAEFIK_CT_IP:?TRAEFIK_CT_IP must be set in .env}"
    docker exec -u www-data nextcloud php occ config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR"
    docker exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value="https"
    docker exec -u www-data nextcloud php occ config:system:delete overwritehost 2>/dev/null || true
    info "✓ Reverse proxy headers configured"

    # Maintenance window at 1 AM UTC (3 AM Bucharest)
    docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=1
    info "✓ Maintenance window set (1 AM UTC)"

    # HSTS header (persistent via .htaccess on the volume)
    if ! docker exec nextcloud grep -q "Strict-Transport-Security" /var/www/html/.htaccess 2>/dev/null; then
        docker exec -u www-data nextcloud bash -c 'cat >> /var/www/html/.htaccess <<EOF

<IfModule mod_headers.c>
  Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
</IfModule>
EOF'
        docker exec nextcloud a2enmod headers > /dev/null 2>&1 || true
        info "✓ HSTS header configured"
    fi

    # Run mimetype migrations and optimize database
    docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive 2>/dev/null || true
    docker exec -u www-data nextcloud php occ db:add-missing-indices 2>/dev/null || true
    docker exec -u www-data nextcloud php occ db:add-missing-columns 2>/dev/null || true
    docker exec -u www-data nextcloud php occ db:add-missing-primary-keys 2>/dev/null || true
    info "✓ Database optimized"

    log "✓ Nextcloud configuration complete"
}

# ==============================================================================
# Set Up Cron Jobs
# ==============================================================================

setup_cron() {
    log "Setting up cron jobs..."

    # Remove any existing nextcloud cron jobs
    (crontab -l 2>/dev/null | grep -v "nightly-backup.sh" | grep -v "nightly-security-updates.sh" | grep -v "cron.php" | grep -v "docker compose up") | crontab - 2>/dev/null || true

    # Start containers on boot (safety net - handles reboot, power loss, etc.)
    (crontab -l 2>/dev/null; echo "@reboot sleep 30 && cd /opt/nextcloud && docker compose up -d >> $LOGS_DIR/boot_startup.log 2>&1") | crontab -

    # Nextcloud background jobs every 5 minutes (recommended by Nextcloud)
    (crontab -l 2>/dev/null; echo "*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php > /dev/null 2>&1") | crontab -

    # Nightly backup at 3 AM
    (crontab -l 2>/dev/null; echo "0 3 * * * cd /opt/nextcloud && /opt/nextcloud/nightly-backup.sh >> $LOGS_DIR/backup_cron.log 2>&1") | crontab -

    # Nightly security updates at 4 AM (after backup)
    (crontab -l 2>/dev/null; echo "0 4 * * * /opt/nextcloud/nightly-security-updates.sh 2>&1") | crontab -

    # Ensure scripts are executable
    chmod +x /opt/nextcloud/nightly-backup.sh /opt/nextcloud/nightly-security-updates.sh 2>/dev/null || true

    # Trigger initial cron run in background so "last background job" timestamp
    # gets set without blocking the deploy (first run after restore processes
    # a backlog of queued jobs and can take several minutes).
    nohup docker exec -u www-data nextcloud php -f /var/www/html/cron.php >/dev/null 2>&1 &
    info "✓ Initial cron run started (background)"

    log "✓ Cron jobs configured (boot: auto-start, background: every 5 min, backup: 3 AM, security updates: 4 AM)"
}

# ==============================================================================
# Display Summary
# ==============================================================================

show_summary() {
    local vm_ip=$(hostname -I | awk '{print $1}')

    echo ""
    info "================================================================"
    info "Nextcloud Bootstrap Complete!"
    info "================================================================"
    echo ""
    echo "  Service URLs:"
    echo "    Nextcloud:    http://$vm_ip:8080"
    echo "    Public:       ${NEXTCLOUD_URL} (via Cloudflare tunnel)"
    echo "    Local LAN:    see TRUSTED_DOMAINS in /opt/nextcloud/.env (set by deploy)"
    echo ""
    echo "  Storage:"
    echo "    Personal:   $MOUNT_PERSONAL (SMB)"
    echo "    Shared:     $MOUNT_SHARED (SMB)"
    echo "    Local DBs:  $LOCAL_DB_ROOT"
    echo "    Backups:    $BACKUP_DIR (SMB, nightly)"
    echo ""
    echo "  Admin:        $NEXTCLOUD_ADMIN_USER"
    echo "  Backup:       Nightly at 3 AM (7-day retention)"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    verify_mounts
    create_directories
    set_permissions
    smart_restore
    start_services
    restore_postgres_if_needed
    configure_nextcloud
    setup_cron
    show_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
