#!/usr/bin/env bash
# ==============================================================================
# Homepage - config push helper (sourced by deploy.sh and update.sh)
# ==============================================================================
# Single writer for /opt/homepage/config/*.yaml inside the Homepage LXC.
# services.yaml and widgets.yaml carry ${VAR} placeholders (service IPs) that
# must be rendered with envsubst before pushing. deploy.sh and update.sh used to
# each carry their own copy of this loop; update.sh's copy skipped envsubst and
# shipped literal "${MEDIA_SERVER_VM_IP}" hostnames, which the LAN search domain
# + wildcard DNS resolved to the reverse proxy - every widget broke.
#
# Requires: CT_ID, SCRIPT_DIR, DEPLOY_ROOT, and a push function taking
# <src> <dest> (deploy.sh: copy_file_to_container, update.sh: pct push wrapper).
# ==============================================================================

HOMEPAGE_CONFIG_FILES=(settings.yaml services.yaml widgets.yaml bookmarks.yaml docker.yaml)
HOMEPAGE_TEMPLATED_FILES=" services.yaml widgets.yaml "

# push_homepage_config <push_fn> <target_dir>
push_homepage_config() {
    local push_fn="$1"
    local target="$2"
    local f

    for f in "${HOMEPAGE_CONFIG_FILES[@]}"; do
        [[ -f "${SCRIPT_DIR}/config/${f}" ]] || continue

        if [[ "$HOMEPAGE_TEMPLATED_FILES" == *" ${f} "* ]]; then
            # envsubst reads the *process environment*, not shell vars - re-source
            # with set -a in a subshell so vars are exported only for this render.
            local tmp_yaml
            tmp_yaml=$(mktemp --suffix=.yaml)
            # envsubst silently renders unset vars as "" (-> "http://:8989"), so
            # check every placeholder the template uses is set before rendering.
            if ! (
                set -a
                [[ -f "${DEPLOY_ROOT}/config/homelab.env" ]] && source "${DEPLOY_ROOT}/config/homelab.env"
                source "${SCRIPT_DIR}/config.env"
                set +a
                missing=""
                for v in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${SCRIPT_DIR}/config/${f}" | tr -d '${}' | sort -u); do
                    [[ -n "${!v:-}" ]] || missing+=" ${v}"
                done
                if [[ -n "$missing" ]]; then
                    log_error "${f}: unset placeholder(s):${missing}"
                    exit 1
                fi
                envsubst < "${SCRIPT_DIR}/config/${f}" > "$tmp_yaml"
            ); then
                rm -f "$tmp_yaml"
                return 1
            fi
            "$push_fn" "$tmp_yaml" "${target}/config/${f}"
            rm -f "$tmp_yaml"
        else
            "$push_fn" "${SCRIPT_DIR}/config/${f}" "${target}/config/${f}"
        fi
        log_info "Pushed ${f}"
    done
}
