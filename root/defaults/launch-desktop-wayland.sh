#!/usr/bin/with-contenv bash
export HOME=/config
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/config/.XDG}"
export XDG_CACHE_HOME=/config/.cache
export TMPDIR=/config/.cache/tmp

LOG_DIR=/config/.hermes/logs
mkdir -p "$LOG_DIR" /config/.brave "$TMPDIR"
LOG="${LOG_DIR}/launch-desktop.log"

{
    echo "=== launch-desktop-wayland $(date -Is) user=$(id -un) ==="
    rm -rf /config/.brave/SingletonLock /config/.brave/SingletonSocket /config/.brave/SingletonCookie

    SOCKET="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-1}"
    for _ in $(seq 1 60); do
        if [ -e "$SOCKET" ]; then
            echo "wayland socket ready: $SOCKET"
            break
        fi
        sleep 1
    done

    BRAVE=/usr/bin/brave-browser
    if [ ! -x "$BRAVE" ]; then
        BRAVE="$(command -v brave-browser-stable || command -v brave-browser || true)"
    fi

    if [ -n "$BRAVE" ] && [ -x "$BRAVE" ]; then
        setsid "$BRAVE" \
            --remote-debugging-port=9222 \
            --remote-debugging-address=127.0.0.1 \
            --user-data-dir=/config/.brave \
            --ozone-platform-hint=auto \
            --no-sandbox \
            --disable-dev-shm-usage \
            --disable-gpu \
            --no-first-run \
            --no-default-browser-check \
            --start-maximized \
            >>"${LOG_DIR}/brave-stdout.log" 2>>"${LOG_DIR}/brave-stderr.log" &
    fi

    foot -T Hermes bash -lc "hermes || true; exec bash" &
    case "${OBSIDIAN_AUTOSTART:-0}" in
        1|true|TRUE|True|yes|YES|Yes)
            if command -v obsidian >/dev/null 2>&1; then
                setsid obsidian >>"${LOG_DIR}/obsidian-stdout.log" 2>>"${LOG_DIR}/obsidian-stderr.log" &
            fi
            ;;
    esac
    wait
} >>"$LOG" 2>&1
