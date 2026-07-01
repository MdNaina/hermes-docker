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
