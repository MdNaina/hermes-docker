# Hermes + Selkies Browser-Agent image
#
# A single image that provides:
#   - A web-native Linux desktop you log into through a browser (Selkies)
#   - A headed Brave window the Hermes agent drives live over CDP
#   - The Hermes gateway (WebUI/messaging) on port 8642
#   - An env-var switch between X11 and Wayland (PIXELFLUX_WAYLAND)
#
# Base tag can be swapped (debiantrixie, fedora44, archetc). Alpine has no
# NVIDIA support; Ubuntu is the safe default.
FROM ghcr.io/linuxserver/baseimage-selkies:ubunturesolute

LABEL maintainer="hermes-docker"
LABEL org.opencontainers.image.title="hermes-docker"
LABEL org.opencontainers.image.description="Selkies web desktop + headed Brave + Hermes agent (CDP), X11/Wayland switchable"

# ---------------------------------------------------------------------------
# Build prerequisites for the Hermes installer, an in-desktop terminal, and the
# Brave apt repository tooling. The Hermes installer pulls its own Python and
# Node.js; we provide ripgrep (fast file search) and ffmpeg (TTS/voice) here so
# the installer detects them as present instead of warning (it can't apt-install
# them itself once the lists are cleared).
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        xz-utils \
        build-essential \
        apt-transport-https \
        ripgrep \
        ffmpeg \
        xterm; \
    # ---- Brave browser (official apt repo) ----
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        > /etc/apt/sources.list.d/brave-browser-release.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        brave-browser; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install Hermes at build time (as root -> the installer uses an FHS layout):
#   - Code:      /usr/local/lib/hermes-agent      (baked, fixed)
#   - Command:   /usr/local/bin/hermes            (baked, fixed, already on PATH)
#   - uv Python: /usr/local/share/uv              (baked, world-readable)
#   - Data:      $HOME/.hermes = /opt/hermes/.hermes  (Node.js + managed uv bin)
#
# IMPORTANT: the abc user's $HOME is /config, which is REPLACED by the mounted
# volume at runtime. The installer-managed runtime deps (Node, uv) land in the
# build-time data dir /opt/hermes/.hermes; the runtime init script symlinks them
# into HERMES_HOME (/config/.hermes) so they resolve against the fresh volume.
# We do NOT touch /usr/local/bin/hermes (the installer already created the real
# launcher there) and make the baked trees world-readable for the abc user.
# ---------------------------------------------------------------------------
RUN set -eux; \
    HOME=/opt/hermes bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'; \
    # The installer (run as root) creates the launcher on PATH; self-heal to the
    # venv entrypoint if its name/location differs, then assert it works.
    if [ ! -x /usr/local/bin/hermes ]; then \
        ln -sf /usr/local/lib/hermes-agent/venv/bin/hermes /usr/local/bin/hermes; \
    fi; \
    test -x /usr/local/bin/hermes; \
    # Telegram gateway adapter requires python-telegram-bot in the Hermes venv (not
    # bundled by the default installer). Bake it so TELEGRAM_* vars in .env work.
    HERMES_VENV=/usr/local/lib/hermes-agent/venv; \
    if [ -x "${HERMES_VENV}/bin/pip" ]; then \
        "${HERMES_VENV}/bin/pip" install --no-cache-dir 'python-telegram-bot==22.8'; \
        "${HERMES_VENV}/bin/python" -c 'import telegram; print("python-telegram-bot", telegram.__version__)'; \
        # Slack gateway adapter (Socket Mode) requires slack-bolt + slack-sdk.
        # Hermes lazy-installs these on first use; baking avoids a runtime pip
        # call that can fail in restricted-network environments.
        "${HERMES_VENV}/bin/pip" install --no-cache-dir 'slack-sdk==3.40.1' 'slack-bolt==1.27.0'; \
        "${HERMES_VENV}/bin/python" -c 'import slack_sdk; print("slack-sdk", slack_sdk.__version__)'; \
        "${HERMES_VENV}/bin/python" -c 'import slack_bolt; print("slack-bolt", slack_bolt.__version__)'; \
    fi; \
    # Make the baked trees world-readable for the abc user (skip any that the
    # installer layout did not create on this version).
    for d in /opt/hermes /usr/local/lib/hermes-agent /usr/local/share/uv; do \
        if [ -e "$d" ]; then chmod -R a+rX "$d"; fi; \
    done; \
    # Pre-build the Hermes dashboard web UI so `hermes dashboard` does not npm install at runtime.
    if [ -d /usr/local/lib/hermes-agent ] && [ -x /opt/hermes/.hermes/node/bin/npm ]; then \
        PATH="/opt/hermes/.hermes/node/bin:${PATH}" \
        HOME=/opt/hermes \
        npm --prefix /usr/local/lib/hermes-agent install --workspace web; \
        PATH="/opt/hermes/.hermes/node/bin:${PATH}" \
        HOME=/opt/hermes \
        npm --prefix /usr/local/lib/hermes-agent run build -w web; \
        # Clean npm cache to reduce image size (~50MB saved).
        rm -rf /root/.npm /opt/hermes/.hermes/node/.cache 2>/dev/null || true; \
    fi

# Persist Hermes state/config/keys in the mounted /config volume.
ENV HERMES_HOME=/config/.hermes

# ---------------------------------------------------------------------------
# Drop in autostart, openbox menu, default Hermes config, init scripts, and the
# gateway-default / hermes-dashboard s6 legacy services (reliable on LSIO base).
# ---------------------------------------------------------------------------
COPY root/ /

RUN set -eux; \
    chmod +x \
        /etc/services.d/hermes-start/run \
        /etc/services.d/hermes-start/finish \
        /defaults/hermes-s6-lib.sh \
        /defaults/gateway-default/run \
        /defaults/gateway-default/finish \
        /defaults/gateway-default/log-run \
        /defaults/hermes-dashboard/run \
        /defaults/hermes-dashboard/finish \
        /defaults/hermes-dashboard/log-run \
        /defaults/launch-desktop.sh \
        /defaults/launch-desktop-wayland.sh \
        /defaults/autostart \
        /defaults/autostart_wayland \
        /custom-cont-init.d/10-hermes-init \
        /custom-cont-init.d/20-reconcile-gateways \
        /custom-cont-init.d/21-reconcile-dashboard \
        /custom-cont-init.d/99-cleanup-stale-dynamic-slots

# Selkies desktop (3000 http / 3001 https) + Hermes gateway (8642) + dashboard (9119)
EXPOSE 3000 3001 8642 9119
