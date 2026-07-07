#!/usr/bin/with-contenv bash
# Launched from Openbox/Labwc autostart. Must stay alive so backgrounded Brave
# is not killed when the autostart shell exits (xterm survives on its own; Brave
# does not when started with a bare trailing &).

export HOME=/config
export DISPLAY="${DISPLAY:-:1}"
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

LOG_DIR=/config/.hermes/logs
mkdir -p "$LOG_DIR" /config/.brave
LOG="${LOG_DIR}/launch-desktop.log"

{
    echo "=== launch-desktop $(date -Is) user=$(id -un) DISPLAY=${DISPLAY} ==="

    # Stale locks prevent Brave from opening a second window after a crash.
    rm -f /config/.brave/SingletonLock /config/.brave/SingletonSocket /config/.brave/SingletonCookie

    for _ in $(seq 1 60); do
        if xset q &>/dev/null; then
            echo "X display ready"
            break
        fi
        sleep 1
    done

    BRAVE=/usr/bin/brave-browser
    if [ ! -x "$BRAVE" ]; then
        BRAVE="$(command -v brave-browser-stable || command -v brave-browser || true)"
    fi
    echo "brave binary: ${BRAVE:-MISSING}"

    # Build GPU flags. BRAVE_DISABLE_GPU defaults to 'true' for widest
    # compatibility (CPU rendering). Set to 'false' to let Brave use GPU
    # acceleration when devices are available (e.g. --device /dev/dri or
    # --gpus all in Docker). Can be overridden per run via env var.
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
        echo "brave pid=$!"
    fi

    xterm -geometry 120x32 -title "Hermes" -e bash -lc "hermes || true; exec bash" &
    echo "xterm pid=$!"

    # Ensure gateway starts once .env exists (covers setup-after-boot).
    (
        # shellcheck source=/defaults/hermes-s6-lib.sh
        source /defaults/hermes-s6-lib.sh
        for _ in $(seq 1 120); do
            if [ -f /config/.hermes/.env ]; then
                if hermes_start_slot gateway-default; then
                    echo "gateway-default started from desktop"
                    break
                fi
            fi
            sleep 5
        done
    ) &

    wait
} >>"$LOG" 2>&1
