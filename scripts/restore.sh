#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_ENV="${PROJECT_DIR}/.env"
BACKUP_PATH=""
YES=false
STOP_CONTAINER=true
CONFIG_OVERRIDE=""
EXTRACT_DIR=""
INSTALL_RUNTIME=true
PULL_IMAGES=false
RESTORE_PROFILE=""

usage() {
    cat <<'EOF'
usage: scripts/restore.sh [BACKUP_PATH] [--yes] [--live] [--data-only] [--pull] [--profile NAME] [--config-dir PATH]

Restores a backup snapshot folder or .zip archive into the configured Hermes
/config volume, then rebuilds and starts the Docker Compose service so image
baked tools such as faster-whisper are installed.

Defaults:
  BACKUP_PATH  ./backups/latest-lean
  stop         Stop the configured container before restore.
  install      Run docker compose build and docker compose up -d after restore.

Examples:
  scripts/restore.sh --yes
  scripts/restore.sh ./backups/20260720T120000Z-lean --yes
  scripts/restore.sh ./backups/20260720T120000Z-lean.zip --yes --pull
  scripts/restore.sh ./backups/latest-lean.zip --yes --profile local
  scripts/restore.sh ./backups/latest-lean --yes --data-only
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) YES=true ;;
        --live) STOP_CONTAINER=false ;;
        --data-only) INSTALL_RUNTIME=false ;;
        --pull) PULL_IMAGES=true ;;
        --profile)
            shift
            RESTORE_PROFILE="${1:-}"
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

if [ -f "${COMPOSE_ENV}" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${COMPOSE_ENV}"
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

dotenv_quote() {
    local value="$1"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    printf '"%s"' "${value}"
}

CONFIG_DIR="$(normalize_path "${CONFIG_OVERRIDE:-${HERMES_CONFIG_VOLUME:-./data}}")"
BACKUP_ROOT="$(normalize_path "${HERMES_BACKUP_DIR:-./backups}")"
BACKUP_PATH="$(normalize_path "${BACKUP_PATH:-${BACKUP_ROOT}/latest-lean}")"
CONTAINER_NAME="${HERMES_CONTAINER_NAME:-hermes-docker}"
runtime_started=false
compose_build_failed=false

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

restore_compose_env_if_missing() {
    local backup_env="${BACKUP_SOURCE}/.hermes-docker/compose.env"
    local tmp

    if [ -f "${COMPOSE_ENV}" ]; then
        return 0
    fi
    if [ ! -f "${backup_env}" ]; then
        if [ "${INSTALL_RUNTIME}" = true ]; then
            echo "No .env found and this backup has no Compose env metadata." >&2
            echo "Run ./setup-hermes-env first, or rerun restore with --data-only." >&2
            exit 78
        fi
        return 0
    fi

    tmp="$(mktemp)"
    grep -v -E '^(HERMES_CONFIG_VOLUME|HERMES_BACKUP_DIR)=' "${backup_env}" > "${tmp}" || true
    {
        cat "${tmp}"
        printf 'HERMES_CONFIG_VOLUME=%s\n' "$(dotenv_quote "${CONFIG_DIR}")"
        printf 'HERMES_BACKUP_DIR=%s\n' "$(dotenv_quote "${BACKUP_ROOT}")"
    } > "${COMPOSE_ENV}"
    rm -f "${tmp}"
    chmod 600 "${COMPOSE_ENV}" 2>/dev/null || true
    echo "Restored Compose env metadata to ${COMPOSE_ENV}"

    set -a
    # shellcheck disable=SC1091
    . "${COMPOSE_ENV}"
    set +a
}

restore_compose_env_if_missing
RESTORE_PROFILE="${RESTORE_PROFILE:-${COMPOSE_PROFILES:-server}}"

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
    if [ "${container_was_running}" = true ] && [ "${runtime_started}" != true ]; then
        echo "Restarting ${CONTAINER_NAME}..."
        docker start "${CONTAINER_NAME}" >/dev/null
    fi
}
trap 'cleanup_extract_dir; restart_container' EXIT

echo "Restoring ${BACKUP_PATH} -> ${CONFIG_DIR}"
rsync -a --delete \
    --exclude='/.hermes-backup-meta' \
    --exclude='/.hermes-docker/' \
    --exclude='/README.md' \
    "${BACKUP_SOURCE}/" "${CONFIG_DIR}/"

if [ "${INSTALL_RUNTIME}" = true ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "docker is required to rebuild/start the restored runtime." >&2
        echo "State restore is complete, but runtime install/start was skipped." >&2
        exit 69
    fi

    echo "Building restored Hermes image with Compose profile: ${RESTORE_PROFILE}"
    if [ "${PULL_IMAGES}" = true ]; then
        if ! COMPOSE_PROFILES="${RESTORE_PROFILE}" docker compose build --pull; then
            compose_build_failed=true
        fi
    else
        if ! COMPOSE_PROFILES="${RESTORE_PROFILE}" docker compose build; then
            compose_build_failed=true
        fi
    fi

    if [ "${compose_build_failed}" = true ]; then
        echo "Docker build failed after the state restore completed." >&2
        echo "If the log contains 'No space left on device', free Docker Desktop/daemon disk space, then rerun restore." >&2
        echo "Useful checks: docker system df" >&2
        echo "Useful cleanup: docker builder prune; docker image prune -a" >&2
        exit 70
    fi

    echo "Starting restored Hermes container..."
    COMPOSE_PROFILES="${RESTORE_PROFILE}" docker compose up -d
    runtime_started=true

    if docker exec "${CONTAINER_NAME}" command -v faster-whisper-transcribe >/dev/null 2>&1; then
        echo "Verified faster-whisper-transcribe is installed in ${CONTAINER_NAME}."
    else
        echo "Warning: faster-whisper-transcribe was not found in ${CONTAINER_NAME}." >&2
    fi
elif [ "${container_was_running}" = true ]; then
    restart_container
    runtime_started=true
fi

echo "Restore complete."
