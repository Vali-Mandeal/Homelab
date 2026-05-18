#!/usr/bin/env bash
# ==============================================================================
# Postfix - Disable Outbound Email
# ==============================================================================
# Proxmox sends email notifications via postfix on port 25, which is blocked
# by most ISPs. Since alerting is handled by Telegram, configure postfix to
# discard all outbound mail silently and flush the stuck queue.
# ==============================================================================

disable_postfix_email() {
    log_section "Disabling Postfix Outbound Email"

    if ! command -v postconf &>/dev/null; then
        log_warn "postfix not installed, skipping"
        return 0
    fi

    # Flush the stuck mail queue
    local queue_count
    queue_count=$(postqueue -p 2>/dev/null | grep -c "^[A-F0-9]" || echo 0)
    if [[ "$queue_count" -gt 0 ]]; then
        log_info "Flushing ${queue_count} stuck message(s) from mail queue..."
        postsuper -d ALL 2>/dev/null || true
        log_info "Mail queue cleared"
    else
        log_info "Mail queue is empty"
    fi

    # Configure postfix to discard all outbound mail
    if postconf default_transport 2>/dev/null | grep -q "discard"; then
        log_info "Postfix already configured to discard mail"
        return 0
    fi

    log_info "Configuring postfix to discard outbound mail..."
    postconf -e "default_transport = discard"
    postconf -e "relay_transport = discard"
    systemctl reload postfix

    log_info "Postfix configured - outbound mail will be silently discarded"
    log_info "Proxmox alerts are handled via Telegram instead"
}
