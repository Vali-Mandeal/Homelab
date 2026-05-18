#!/usr/bin/env bash
# ==============================================================================
# Locale Configuration
# ==============================================================================
# Fix SSH locale warnings by generating and configuring UTF-8 locales
# ==============================================================================

# ==============================================================================
# Main Entry Point
# ==============================================================================

configure_system_locale() {
    log_section "Configuring System Locale"

    if ! is_locale_generation_available; then
        log_info "Locale generation not available on this system"
        return 0
    fi

    generate_utf8_locales
    set_default_locale

    log_info "Locale configuration complete"
    log_info "SSH locale warnings will be fixed after next login"
}

# ==============================================================================
# Validation Functions
# ==============================================================================

is_locale_generation_available() {
    [[ -f "/etc/locale.gen" ]]
}

# ==============================================================================
# Implementation Functions
# ==============================================================================

generate_utf8_locales() {
    log_info "Generating UTF-8 locales..."

    enable_locale_in_config "en_US.UTF-8 UTF-8"
    enable_locale_in_config "en_GB.UTF-8 UTF-8"

    locale-gen
    log_info "Locales generated successfully"
}

enable_locale_in_config() {
    local locale="$1"
    local escaped_locale
    escaped_locale=$(echo "$locale" | sed 's/\./\\./g')

    if grep -q "^${locale}$" /etc/locale.gen 2>/dev/null; then
        log_info "Locale ${locale} already enabled"
        return 0
    fi

    sed -i "s/^# *${escaped_locale}/${locale}/" /etc/locale.gen
}

set_default_locale() {
    log_info "Setting system default locale..."

    update-locale LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8

    cat > /etc/default/locale << EOF
LANG=en_US.UTF-8
LC_CTYPE=en_US.UTF-8
EOF

    log_info "Default locale set to en_US.UTF-8"
}
