#!/bin/sh
# ==============================================================================
# OnlyOffice Document Server - entrypoint wrapper
# ==============================================================================
# Bind-mounted into the onlyoffice container and set as its entrypoint in
# docker-compose.yml. Applies the patch below, then execs the image's own
# entrypoint unchanged.
#
# Why: from Document Server 9.4 every editor loads web-apps/apps/common/
# Analytics.js at startup. Ad blockers (Brave Shields, uBlock/EasyPrivacy,
# Firefox ETP) block any file named "Analytics.js", the editor's service worker
# fetch rejects, and the editor never finishes loading (blank frame). The module
# is an inert Google Analytics wrapper - the stack never gives it a tracking id.
# Upstream: https://github.com/ONLYOFFICE/DocumentServer/issues/3686
#
# Fix: serve the same module under a neutral name and point the six editor
# bootstraps at it. Runs on every container start because image updates restore
# the originals. Idempotent, and a no-op once upstream stops referencing
# common/Analytics - at that point this wrapper can be removed.
# ==============================================================================

set -eu

APPS=/var/www/onlyoffice/documentserver/web-apps/apps
OLD=common/Analytics
NEW=common/DocEvents

if [ -f "${APPS}/${OLD}.js" ]; then
    cp -f "${APPS}/${OLD}.js" "${APPS}/${NEW}.js"
    gzip -9 -n -c "${APPS}/${NEW}.js" > "${APPS}/${NEW}.js.gz"
fi

# nginx serves these with gzip_static, so each patched app.js needs its .gz
# regenerated - otherwise browsers keep receiving the unpatched precompressed copy.
grep -rlF --include=app.js "${OLD}" "${APPS}" 2>/dev/null | while read -r f; do
    sed -i "s|${OLD}|${NEW}|g" "$f"
    gzip -9 -n -c "$f" > "${f}.gz"
    echo "[onlyoffice-entrypoint] patched ${f#${APPS}/}"
done

exec /app/ds/run-document-server.sh "$@"
