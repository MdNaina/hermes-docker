#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="lean"
STOP_CONTAINER=true
BACKUP_ROOT=""
CONFIG_OVERRIDE=""
WRITE_ZIP=false

usage() {
    cat <<'EOF'
usage: scripts/backup.sh [--lean|--full] [--live] [--zip] [--config-dir PATH] [--backup-dir PATH]

Creates an incremental rsync snapshot of the configured Hermes /config volume.

Defaults:
  --lean   Keep session/auth/database/browser state, skip caches and logs.
  stop     Stop the configured container briefly for a consistent snapshot.

Examples:
  scripts/backup.sh
  scripts/backup.sh --zip
  scripts/backup.sh --full
  scripts/backup.sh --live --backup-dir /secure/hermes-backups
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --lean) MODE="lean" ;;
        --full) MODE="full" ;;
        --live) STOP_CONTAINER=false ;;
        --zip) WRITE_ZIP=true ;;
        --backup-dir)
            shift
            BACKUP_ROOT="${1:-}"
            ;;
        --config-dir)
            shift
            CONFIG_OVERRIDE="${1:-}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required for incremental backups." >&2
    exit 69
fi

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${PROJECT_DIR}/.env"
    set +a
fi

normalize_path() {
    local value="$1"
    case "${value}" in
        "~") value="${HOME:-${PROJECT_DIR}}" ;;
        "~/"*) value="${HOME:-${PROJECT_DIR}}/${value#~/}" ;;
    esac
    case "${value}" in
        /*) printf '%s' "${value}" ;;
        *) printf '%s/%s' "${PROJECT_DIR}" "${value}" ;;
    esac
}

CONFIG_DIR="$(normalize_path "${CONFIG_OVERRIDE:-${HERMES_CONFIG_VOLUME:-./data}}")"
BACKUP_ROOT="$(normalize_path "${BACKUP_ROOT:-${HERMES_BACKUP_DIR:-./backups}}")"
CONTAINER_NAME="${HERMES_CONTAINER_NAME:-hermes-docker}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${BACKUP_ROOT}/${STAMP}-${MODE}"
ZIP_DEST="${BACKUP_ROOT}/${STAMP}-${MODE}.zip"
LATEST_LINK="${BACKUP_ROOT}/latest-${MODE}"
LATEST_ZIP_LINK="${BACKUP_ROOT}/latest-${MODE}.zip"

if [ ! -d "${CONFIG_DIR}" ]; then
    echo "Config volume does not exist: ${CONFIG_DIR}" >&2
    exit 66
fi

mkdir -p "${DEST}"

container_was_running=false
if [ "${STOP_CONTAINER}" = true ] && command -v docker >/dev/null 2>&1; then
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1 \
        && [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" = "true" ]; then
        echo "Stopping ${CONTAINER_NAME} for a consistent backup..."
        docker stop "${CONTAINER_NAME}" >/dev/null
        container_was_running=true
    fi
fi

restart_container() {
    if [ "${container_was_running}" = true ]; then
        echo "Restarting ${CONTAINER_NAME}..."
        docker start "${CONTAINER_NAME}" >/dev/null
    fi
}
trap restart_container EXIT

exclude_file="$(mktemp)"
cleanup() {
    rm -f "${exclude_file}" 2>/dev/null || true
}
trap 'cleanup; restart_container' EXIT

if [ "${MODE}" = "lean" ]; then
    cat > "${exclude_file}" <<'EOF'
/.cache/
/.npm/
/.local/share/Trash/
/.hermes/logs/
/.hermes/*.lock
/.hermes/*.pid
/.browser-harness/tmp/
/.brave/Crashpad/
/.brave/GrShaderCache/
/.brave/GraphiteDawnCache/
/.brave/ShaderCache/
/.brave/Safe Browsing/
/.brave/component_crx_cache/
/.brave/Default/Cache/
/.brave/Default/Code Cache/
/.brave/Default/GPUCache/
/.brave/Default/Service Worker/CacheStorage/
/.brave/Default/Session Storage/
/README.md
EOF
else
    cat > "${exclude_file}" <<'EOF'
/.X11-unix/
/.XDG/
/.dbus/
/.config/pulse/
/.brave/SingletonSocket
/.brave/SingletonLock
/.brave/SingletonCookie
EOF
fi

rsync_args=(-a --quiet --no-devices --no-specials --delete --exclude-from "${exclude_file}")
if [ -L "${LATEST_LINK}" ] && [ -d "${LATEST_LINK}" ]; then
    rsync_args+=(--link-dest "$(cd "${LATEST_LINK}" && pwd)")
fi

echo "Backing up ${CONFIG_DIR} -> ${DEST}"
rsync "${rsync_args[@]}" "${CONFIG_DIR}/" "${DEST}/"

cat > "${DEST}/.hermes-backup-meta" <<EOF
created_at=${STAMP}
mode=${MODE}
source=${CONFIG_DIR}
container=${CONTAINER_NAME}
stopped_container=${container_was_running}
EOF

ln -sfn "$(basename "${DEST}")" "${LATEST_LINK}"

if [ "${WRITE_ZIP}" = true ]; then
    if ! command -v zip >/dev/null 2>&1; then
        echo "zip is required for --zip archives." >&2
        exit 69
    fi
    echo "Writing portable zip archive: ${ZIP_DEST}"
    (
        cd "${DEST}"
        find . -type s -delete
        zip -qry "${ZIP_DEST}" .
    )
    ln -sfn "$(basename "${ZIP_DEST}")" "${LATEST_ZIP_LINK}"
fi

echo
echo "Backup complete:"
echo "  ${DEST}"
if [ "${WRITE_ZIP}" = true ]; then
    echo "Zip archive:"
    echo "  ${ZIP_DEST}"
fi
echo "Latest pointer:"
echo "  ${LATEST_LINK}"
if [ "${WRITE_ZIP}" = true ]; then
    echo "Latest zip pointer:"
    echo "  ${LATEST_ZIP_LINK}"
fi
echo "Snapshot size (hard-linked files may share disk blocks):"
du -sh "${DEST}" 2>/dev/null || true
if [ "${WRITE_ZIP}" = true ]; then
    echo "Zip size:"
    du -sh "${ZIP_DEST}" 2>/dev/null || true
fi
