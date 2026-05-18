#!/usr/bin/env bash
# ==============================================================================
# Proxmox API User Creation
# ==============================================================================
# Purpose: Create API users for automation tools with appropriate roles
# CRITICAL: Must be idempotent - checks before creating/modifying
# ==============================================================================

setup_proxmox_api_users() {
    log_section "Setting Up Proxmox API Users"

    create_homepage_api_user

    log_info "API users configuration complete"
}

create_homepage_api_user() {
    local user="homepage@pam"
    local linux_user="homepage"
    local token_name="monitoring"

    log_info "Configuring Homepage monitoring user..."

    # PAM users require a matching Linux system user
    if id "$linux_user" &>/dev/null; then
        log_info "System user ${linux_user} already exists"
    else
        useradd -r -s /usr/sbin/nologin "$linux_user"
        log_info "Created system user ${linux_user}"
    fi

    # Create PVE user
    if pveum user list --output-format json | grep -q "\"${user}\""; then
        log_info "PVE user ${user} already exists"
    else
        pveum user add "${user}" --comment "Homepage dashboard read-only"
        log_info "Created PVE user ${user}"
    fi

    # Assign PVEAuditor role
    pveum aclmod / -user "${user}" -role PVEAuditor
    log_info "Assigned PVEAuditor role to ${user}"

    # Create API token
    if pveum user token list "${user}" --output-format json 2>/dev/null | grep -q "\"${token_name}\""; then
        log_info "Token ${user}!${token_name} already exists"
    else
        log_info "Creating API token ${user}!${token_name}..."
        local token_output
        token_output=$(pveum user token add "${user}" "${token_name}" --privsep=0 --output-format json)

        local token_secret
        token_secret=$(echo "$token_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

        log_warn "======================================================="
        log_warn "SAVE THIS TOKEN SECRET (shown only once):"
        log_warn "Token ID: ${user}!${token_name}"
        log_warn "Token Secret: ${token_secret}"
        log_warn "Update homepage widgets.yaml with this secret"
        log_warn "======================================================="
    fi
}

# ==============================================================================
# Generic API User Creation Template
# ==============================================================================
#
# create_custom_user() {
#     local user="$1"
#     local role="$2"
#     local token_name="$3"
#     local privileges="$4"
#
#     log_info "Configuring ${user}..."
#
#     # Create user if not exists
#     if pveum user list | grep -q "│ ${user} "; then
#         log_info "User ${user} already exists"
#     else
#         pveum user add "${user}"
#         log_info "✓ Created user ${user}"
#     fi
#
#     # Create role if not exists
#     if pveum role list | grep -q "│ ${role} "; then
#         log_info "Role ${role} already exists"
#     else
#         pveum role add "${role}" -privs "${privileges}"
#         log_info "✓ Created role ${role}"
#     fi
#
#     # Assign role
#     pveum aclmod / -user "${user}" -role "${role}"
#     log_info "✓ Assigned ${role} role to ${user}"
#
#     # Create token if not exists
#     if pveum user token list "${user}" 2>/dev/null | grep -q "│ ${token_name} "; then
#         log_info "Token ${user}!${token_name} already exists"
#     else
#         log_info "Creating API token ${user}!${token_name}..."
#         local token_output
#         token_output=$(pveum user token add "${user}" "${token_name}" --privsep=0 2>&1)
#
#         local token_secret
#         token_secret=$(echo "$token_output" | grep -oP '(?<=value )[a-f0-9-]+' | head -n1)
#
#         if [[ -n "$token_secret" ]]; then
#             log_warn "================================================"
#             log_warn "SAVE THIS TOKEN SECRET (shown only once):"
#             log_warn "Token ID: ${user}!${token_name}"
#             log_warn "Token Secret: ${token_secret}"
#             log_warn "================================================"
#         fi
#     fi
# }
