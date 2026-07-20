# Hermes + Selkies Browser-Agent image
#
# A single image that provides:
#   - A web-native Linux desktop you log into through a browser (Selkies)
#   - A headed Brave window the Hermes agent drives live over CDP
#   - The Hermes gateway (WebUI/messaging) on port 8642
#   - An env-var switch between X11 and Wayland (PIXELFLUX_WAYLAND)
#
# Base tag can be swapped (debiantrixie, fedora44, archetc). Alpine has no
# NVIDIA support; Ubuntu is the safe default. The digest pins the multi-arch
# index for ubunturesolute as inspected on 2026-07-19.
FROM ghcr.io/linuxserver/baseimage-selkies:ubunturesolute@sha256:70bbcf59fab718390f91f3ddcbb7c51a0a27c8f6aea09f8ca6a756c3c882973b

LABEL maintainer="hermes-docker"
LABEL org.opencontainers.image.title="hermes-docker"
LABEL org.opencontainers.image.description="Selkies web desktop + headed Brave + Hermes agent (CDP), X11/Wayland switchable"

# ---------------------------------------------------------------------------
# Build prerequisites for the Hermes installer, an in-desktop terminal, and the
# Brave apt repository tooling. The Hermes installer pulls its own Python and
# Node.js. Keep the default package set lean because Docker Desktop builders can
# have a small /var/cache/apt/archives budget, especially on arm64.
# ---------------------------------------------------------------------------
ARG INSTALL_OPTIONAL_BUILD_TOOLS=false
ARG OBSIDIAN_VERSION=1.12.7
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        xz-utils \
        apt-transport-https \
        ripgrep \
        wmctrl \
        xterm; \
    apt-get clean; \
    rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*; \
    if [ "${INSTALL_OPTIONAL_BUILD_TOOLS}" = "true" ]; then \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            build-essential \
            ffmpeg; \
        apt-get clean; \
        rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*; \
    fi; \
    # ---- Brave browser (official apt repo) ----
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        > /etc/apt/sources.list.d/brave-browser-release.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        brave-browser; \
    # ---- Obsidian AppImage (official GitHub release asset) ----
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "${dpkg_arch}" in \
        amd64) obsidian_arch_suffix="" ;; \
        arm64) obsidian_arch_suffix="-arm64" ;; \
        *) echo "Unsupported Obsidian architecture: ${dpkg_arch}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/obsidian; \
    curl -fL \
        "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/Obsidian-${OBSIDIAN_VERSION}${obsidian_arch_suffix}.AppImage" \
        -o /opt/obsidian/Obsidian.AppImage; \
    chmod +x /opt/obsidian/Obsidian.AppImage; \
    apt-get clean; \
    rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*

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
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "${dpkg_arch}" in \
        amd64) export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 ;; \
        arm64) export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-arm64 ;; \
        *) echo "Unsupported Playwright architecture: ${dpkg_arch}" >&2; exit 1 ;; \
    esac; \
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
    HERMES_UV=/opt/hermes/.hermes/bin/uv; \
    test -x "${HERMES_VENV}/bin/python"; \
    test -x "${HERMES_UV}"; \
    "${HERMES_UV}" pip install --python "${HERMES_VENV}/bin/python" 'python-telegram-bot==22.8'; \
    "${HERMES_VENV}/bin/python" -c 'import telegram; print("python-telegram-bot", telegram.__version__)'; \
    # Browser Harness is a separate CDP harness/skill. Bake the command and
    # skill generated from the installed package for Hermes to use at runtime.
    HOME=/opt/hermes "${HERMES_UV}" tool install --python 3.12 --upgrade --force 'browser-harness==0.1.6'; \
    ln -sf /opt/hermes/.local/bin/browser-harness /usr/local/bin/browser-harness; \
    mkdir -p /opt/hermes/default-skills/browser-harness; \
    HOME=/opt/hermes XDG_CONFIG_HOME=/opt/hermes/.config \
        browser-harness skill > /opt/hermes/default-skills/browser-harness/SKILL.md; \
    test -s /opt/hermes/default-skills/browser-harness/SKILL.md; \
    # Make the baked trees world-readable for the abc user (skip any that the
    # installer layout did not create on this version).
    for d in /opt/hermes /usr/local/lib/hermes-agent /usr/local/share/uv; do \
        if [ -e "$d" ]; then chmod -R a+rX "$d"; fi; \
    done; \
    # Pre-build the Hermes dashboard web UI so `hermes dashboard` does not npm install at runtime.
    # Prefer the upstream lockfile when present; fall back to install because the
    # remote Hermes installer owns this tree and may change packaging format.
    if [ -d /usr/local/lib/hermes-agent ] && [ -x /opt/hermes/.hermes/node/bin/npm ]; then \
        if [ -f /usr/local/lib/hermes-agent/package-lock.json ]; then \
            npm_install_cmd=ci; \
        else \
            npm_install_cmd=install; \
        fi; \
        PATH="/opt/hermes/.hermes/node/bin:${PATH}" \
        HOME=/opt/hermes \
        npm --prefix /usr/local/lib/hermes-agent "${npm_install_cmd}" --workspace web --no-fund --no-audit --progress=false; \
        PATH="/opt/hermes/.hermes/node/bin:${PATH}" \
        HOME=/opt/hermes \
        npm --prefix /usr/local/lib/hermes-agent run build -w web; \
        PATH="/opt/hermes/.hermes/node/bin:${PATH}" \
        HOME=/opt/hermes \
        npm --prefix /usr/local/lib/hermes-agent "${npm_install_cmd}" --workspace ui-tui --include=dev --silent --no-fund --no-audit --progress=false; \
        PATH="/opt/hermes/.hermes/node/bin:${PATH}" \
        HOME=/opt/hermes \
        npm --prefix /usr/local/lib/hermes-agent run build -w ui-tui; \
    fi

# Keep local speech-to-text isolated from Hermes itself. Models are not
# downloaded at build time; they are cached under /config on first use.
ARG FASTER_WHISPER_VERSION=1.2.1
RUN set -eux; \
    HERMES_UV=/opt/hermes/.hermes/bin/uv; \
    test -x "${HERMES_UV}"; \
    mkdir -p /opt/faster-whisper; \
    "${HERMES_UV}" venv --python 3.12 /opt/faster-whisper/venv; \
    "${HERMES_UV}" pip install --python /opt/faster-whisper/venv/bin/python \
        "faster-whisper==${FASTER_WHISPER_VERSION}"; \
    /opt/faster-whisper/venv/bin/python -c 'import importlib.metadata as m; print("faster-whisper", m.version("faster-whisper"))'; \
    chmod -R a+rX /opt/faster-whisper

# Persist Hermes state/config/keys in the mounted /config volume.
ENV HERMES_HOME=/config/.hermes
ENV HERMES_WEB_DIST=/usr/local/lib/hermes-agent/hermes_cli/web_dist
ENV HERMES_TUI_DIR=/usr/local/lib/hermes-agent/ui-tui
ENV BU_CDP_URL=http://127.0.0.1:9222
ENV BROWSER_HARNESS_HOME=/config/.browser-harness
ENV BH_HOME=/config/.browser-harness
ENV FASTER_WHISPER_HOME=/config/.cache/faster-whisper
ENV HF_HOME=/config/.cache/huggingface

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
        /custom-cont-init.d/99-cleanup-stale-dynamic-slots \
        /usr/local/bin/faster-whisper-transcribe \
        /usr/local/bin/hermes-smoke-check \
        /usr/local/bin/obsidian

# Selkies desktop (3000 http / 3001 https) + Hermes gateway (8642) + dashboard (9119)
EXPOSE 3000 3001 8642 9119
