#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_PATH=""
YES=false
STOP_CONTAINER=true
CONFIG_OVERRIDE=""
EXTRACT_DIR=""

usage() {
    cat <<'EOF'
usage: scripts/restore.sh [BACKUP_PATH] [--yes] [--live] [--config-dir PATH]

Restores a backup snapshot folder or .zip archive into the configured Hermes
/config volume.

Defaults:
  BACKUP_PATH  ./backups/latest-lean
  stop         Stop the configured container before restore.

Examples:
  scripts/restore.sh --yes
  scripts/restore.sh ./backups/20260720T120000Z-lean --yes
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) YES=true ;;
        --live) STOP_CONTAINER=false ;;
        --config-dir)
            shift
            CONFIG_OVERRIDE="${1:-}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -z "${BACKUP_PATH}" ]; then
                BACKUP_PATH="$1"
            else
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 64
            fi
            ;;
    esac
    shift
done

if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required for restore." >&2
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
BACKUP_ROOT="$(normalize_path "${HERMES_BACKUP_DIR:-./backups}")"
BACKUP_PATH="$(normalize_path "${BACKUP_PATH:-${BACKUP_ROOT}/latest-lean}")"
CONTAINER_NAME="${HERMES_CONTAINER_NAME:-hermes-docker}"

cleanup_extract_dir() {
    if [ -n "${EXTRACT_DIR}" ]; then
        rm -rf "${EXTRACT_DIR}" 2>/dev/null || true
    fi
}

case "${BACKUP_PATH}" in
    *.zip)
        if [ ! -f "${BACKUP_PATH}" ]; then
            echo "Backup archive does not exist: ${BACKUP_PATH}" >&2
            exit 66
        fi
        if ! command -v unzip >/dev/null 2>&1; then
            echo "unzip is required to restore .zip archives." >&2
            exit 69
        fi
        EXTRACT_DIR="$(mktemp -d)"
        unzip -q "${BACKUP_PATH}" -d "${EXTRACT_DIR}"
        BACKUP_SOURCE="${EXTRACT_DIR}"
        ;;
    *)
        if [ ! -d "${BACKUP_PATH}" ]; then
            echo "Backup path does not exist: ${BACKUP_PATH}" >&2
            exit 66
        fi
        BACKUP_SOURCE="${BACKUP_PATH}"
        ;;
esac

if [ ! -d "${BACKUP_SOURCE}" ]; then
    echo "Backup source is not a directory after preparation: ${BACKUP_SOURCE}" >&2
    exit 66
fi

if [ "${YES}" != true ]; then
    echo "Restore will replace ${CONFIG_DIR} with:"
    echo "  ${BACKUP_PATH}"
    echo
    echo "This includes Hermes auth, agent databases, and Brave session state."
    printf 'Continue? [y/N]: '
    read -r answer || answer=""
    case "${answer}" in
        y|Y|yes|YES) ;;
        *) echo "Restore cancelled."; exit 0 ;;
    esac
fi

mkdir -p "${CONFIG_DIR}"

container_was_running=false
if [ "${STOP_CONTAINER}" = true ] && command -v docker >/dev/null 2>&1; then
    if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1 \
        && [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" = "true" ]; then
        echo "Stopping ${CONTAINER_NAME} for restore..."
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
trap 'cleanup_extract_dir; restart_container' EXIT

echo "Restoring ${BACKUP_PATH} -> ${CONFIG_DIR}"
rsync -a --delete \
    --exclude='/.hermes-backup-meta' \
    --exclude='/README.md' \
    "${BACKUP_SOURCE}/" "${CONFIG_DIR}/"

echo "Restore complete."
