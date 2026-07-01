#!/usr/bin/with-contenv bash
export HOME=/config
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/config/.XDG}"

LOG_DIR=/config/.hermes/logs
mkdir -p "$LOG_DIR" /config/.brave
LOG="${LOG_DIR}/launch-desktop.log"

{
    echo "=== launch-desktop-wayland $(date -Is) user=$(id -un) ==="
    rm -f /config/.brave/SingletonLock /config/.brave/SingletonSocket /config/.brave/SingletonCookie

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

    # Build GPU flags. BRAVE_DISABLE_GPU defaults to 'true' for widest
    # compatibility (CPU rendering). Set to 'false' to let Brave use GPU
    # acceleration when devices are available.
    brave_gpu_flags=""
    case "${BRAVE_DISABLE_GPU:-true}" in
        1|true|TRUE|True|yes|YES|Yes) brave_gpu_flags="--disable-gpu" ;;
        *)                              brave_gpu_flags=""               ;;
    esac

    if [ -n "$BRAVE" ] && [ -x "$BRAVE" ]; then
        setsid "$BRAVE" \
            --remote-debugging-port=9222 \
            --remote-debugging-address=127.0.0.1 \
            --user-data-dir=/config/.brave \
            --ozone-platform-hint=auto \
            --no-sandbox \
            --disable-dev-shm-usage \
            ${brave_gpu_flags:+$brave_gpu_flags} \
            --no-first-run \
            --no-default-browser-check \
            --start-maximized \
            >>"${LOG_DIR}/brave-stdout.log" 2>>"${LOG_DIR}/brave-stderr.log" &
    fi

    foot -T Hermes bash -lc "hermes || true; exec bash" &
    wait
} >>"$LOG" 2>&1
