# hermes-docker

A single Docker image that bundles a **web-native Linux desktop**, a **headed Brave**
browser the **[Hermes agent](https://hermes-agent.nousresearch.com/)** drives live over
CDP, and the **Hermes gateway** (API / messaging) — built on the
[LinuxServer Selkies base image](https://docs.linuxserver.io/images/docker-baseimage-selkies/).

You log in through your browser, watch the agent click and type in a real Brave
window, and optionally chat with the same agent from anywhere via the gateway.
**X11 and Wayland are switchable with a single environment variable.**

## What's inside

| Component | Purpose | Port |
| --- | --- | --- |
| Selkies | Web-native desktop streamed to your browser | `3001` (https), `3000` (http) |
| Brave | Headed browser launched with `--remote-debugging-port=9222` | (internal `9222`, loopback only) |
| Browser Harness | Self-healing CDP harness and Hermes skill, attached to headed Brave | - |
| faster-whisper | Local speech-to-text CLI with persistent model cache | - |
| Obsidian | Headed desktop app for local Markdown vaults in `/config` | - |
| Hermes CLI | `hermes` running in an `xterm` inside the desktop | - |
| Hermes gateway | `hermes gateway run` (API / Telegram / Discord; `/health` check) | `8642` |
| Hermes dashboard | Web UI (`HERMES_DASHBOARD=1`, starts after gateway) | `9119` |

```
You (browser)
  │  https :3001  ───────────────►  Selkies desktop  ──►  Brave (headed)
  │  http  :8642  ───────────────►  Hermes gateway        ▲   ▲
  │  http  :9119  ───────────────►  Hermes dashboard      │   │ CDP 127.0.0.1:9222
                                    hermes CLI (xterm) ───┘───┘
```

## Architecture notes

- **Persistence:** in the Selkies base the `abc` user's `$HOME` is `/config`, and
  `/config` is replaced by the mounted volume at runtime. So the Hermes **code** is
  baked into `/opt/hermes` (ships in the image) while `HERMES_HOME=/config/.hermes`
  keeps **config / API keys / memory** in the persistent volume.
- **Browser control:** Brave starts headed in the desktop with remote debugging on
  loopback `9222`. Browser Harness is installed and registered as a Hermes skill,
  with `BU_CDP_URL=http://127.0.0.1:9222`, so agent browser work can use the
  self-healing harness against the visible Brave session. Hermes' native
  `browser` toolset remains enabled as a fallback.
- **Desktop apps:** Obsidian is installed from the official Linux AppImage release
  and can run in the same visible desktop when launched from the menu or terminal.
  Vault files live under the persistent `/config` volume. It does not autostart
  by default, so Brave and the Hermes terminal remain the first-run focus.
- **Speech-to-text:** faster-whisper is installed in an isolated venv at
  `/opt/faster-whisper/venv`. Model downloads/cache live under `/config/.cache`
  by default, so transcribed models persist across container restarts.
- **X11 / Wayland:** handled by the base image's `PIXELFLUX_WAYLAND` env var — no
  custom plumbing. Brave is launched with `--ozone-platform-hint=auto` so the same
  image renders correctly in either mode.

## Quick start

### With Docker Compose

```bash
# 1. Generate .env and seed the selected /config state directory.
#    If the image is missing, the script builds hermes-docker first.
./setup-hermes-env

# 2. Start the server
docker compose up -d --build

# 3. Local profile only: open the desktop and log in with the credentials
#    from the wizard: https://localhost:3001
```

The setup wizard defaults to the `server` Compose profile. That profile does not
publish desktop, gateway, or dashboard ports directly to the host; put it behind
a reverse proxy or VPN. Choose `local` during setup for the old localhost port
publishing behavior.

### With plain docker run

```bash
docker build -t hermes-docker .

docker run -d --name "$(basename "$PWD")" \
  --shm-size=2gb \
  --security-opt seccomp=unconfined \
  -p 3001:3001 -p 8642:8642 -p 9119:9119 \
  -e CUSTOM_USER=<desktop-user> \
  -e PASSWORD=<desktop-password> \
  -e TITLE="Hermes Desktop" \
  -e PIXELFLUX_WAYLAND=false \
  -e HERMES_DASHBOARD=1 \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<dashboard-user> \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<dashboard-password> \
  -v "$PWD/data:/config" \
  hermes-docker
```

## First-run setup (server bootstrap)

No API keys are baked in. Run the host-side wizard once before starting Docker:

```bash
./setup-hermes-env
docker compose up -d --build
```

The wizard writes:

- `.env` for Docker Compose profile, credentials, state path, bind address, and
  dashboard settings
- `COMPOSE_PROJECT_NAME` and `HERMES_CONTAINER_NAME`, defaulting to the current
  folder name so multiple checkouts can run side by side
- `COMPOSE_PROFILES=server` by default, or `local` if you choose direct host
  port publishing
- `HERMES_CONFIG_VOLUME`, the host path mounted as `/config`
- `HERMES_BACKUP_DIR`, defaulting to a sibling path ending in `-backups`
- published host ports for Selkies, gateway, and dashboard when using the
  `local` profile; choose different ports for each local instance
- `$HERMES_CONFIG_VOLUME/.hermes/.env` for Hermes gateway/API secrets, provider
  keys, and Telegram or Slack tokens
- `$HERMES_CONFIG_VOLUME/.hermes/config.yaml` for the selected provider/model
  and browser config

If you leave the desktop password blank, the wizard generates one and prints it
before starting Hermes' native setup flow. Dashboard login uses the same password
unless you enter a separate dashboard password.

For remote servers, prefer an encrypted host path outside this checkout for
`HERMES_CONFIG_VOLUME`, such as `/srv/hermes-docker/config` or
`$HOME/.local/share/hermes-docker`. The default local `data/` directory is
ignored by Git and Docker build context, but it still contains browser sessions,
OAuth credentials, API keys, agent memory, and gateway state.

The container then starts unattended: the **gateway API** starts on `:8642`, the
**dashboard Web UI** starts on `:9119`, and the visible Brave session is
available when you open the Selkies desktop. In the `server` profile those ports
are internal only. `http://localhost:8642/` may return `404`; use
`http://localhost:8642/health` for the gateway health check.

With a Nous Portal subscription, the wizard can write the model choice, but OAuth
still requires a browser login. Run `hermes setup --portal` once from the desktop
if `$HERMES_CONFIG_VOLUME/.hermes/auth.json` is not already present.

Start chatting in the terminal with `hermes`, and ask it to browse — its actions
   appear live in the Brave window. (In the CLI you can also run `/browser status`
   to confirm the CDP connection, or `/browser connect` to attach manually.)

### Compose profiles

| Profile | Service | Host ports | Use case |
| --- | --- | --- | --- |
| `server` | `hermes-server` | none | Remote host behind reverse proxy, WireGuard/Tailscale, or SSH tunnel |
| `local` | `hermes-local` | `3001`, `3000`, `8642`, `9119` | Local workstation or trusted LAN testing |

The optional `docker-compose.server.yml` attaches `hermes-server` to an external
reverse-proxy/VPN network without publishing ports:

```bash
docker network create hermes-edge
docker compose -f docker-compose.yml -f docker-compose.server.yml up -d --build
```

Set `HERMES_REVERSE_PROXY_NETWORK` if your proxy already uses another external
network name. Do not enable both profiles at the same time because both services
use the same configured container name.

### Brave / browser automation

Brave starts from `/defaults/launch-desktop.sh` when the Selkies desktop opens.
That script stays alive (`wait`) so Brave is not killed when Openbox autostart
exits — a bare `brave-browser ... &` line fails silently while xterm still works.

Verify:

```bash
cat /config/.config/openbox/autostart
tail -20 /config/.hermes/logs/launch-desktop.log
tail -20 /config/.hermes/logs/brave-stderr.log
pgrep -a brave
```

If Hermes says browser tools are unavailable, check `/config/.hermes/config.yaml`
contains `toolsets: [browser]` and `browser.cdp_url: ws://127.0.0.1:9222`.

Browser Harness is also installed in the image and seeded into
`/config/.hermes/skills/browser-harness/SKILL.md` on container start. It attaches
to the same headed Brave through `BU_CDP_URL=http://127.0.0.1:9222`.

Verify:

```bash
browser-harness <<'PY'
print(page_info())
PY
```

`BH_DOMAIN_SKILLS=0` by default. Set it to `1` only if you want Browser Harness
to persist and reuse site-specific skills under `/config/.browser-harness`.

### faster-whisper

The image includes SYSTRAN `faster-whisper` for local speech-to-text. It is
installed separately from Hermes and exposed as:

```bash
faster-whisper-transcribe /config/path/to/audio.mp3
```

Useful options:

```bash
faster-whisper-transcribe --model base --device cpu --compute-type int8 input.wav
faster-whisper-transcribe --model small --language en --format json input.mp4
faster-whisper-transcribe --format srt input.wav
```

Default cache paths:

```bash
FASTER_WHISPER_HOME=/config/.cache/faster-whisper
HF_HOME=/config/.cache/huggingface
```

Models are downloaded on first use, not during Docker build. CPU defaults to
`compute_type=int8`; for CUDA, configure the Docker GPU runtime and set
`FASTER_WHISPER_DEVICE=cuda`.

### Obsidian and app launching

Obsidian is available as `obsidian` inside the desktop, but it does not autostart
by default. Launch it from the desktop menu or from the Hermes terminal:

```bash
obsidian
```

To start Obsidian automatically with Brave and the Hermes terminal, set this in
`.env`:

```bash
OBSIDIAN_AUTOSTART=1
```

Window switching is limited by what the browser/Selkies session captures. The
official LinuxServer Selkies documentation covers desktop autostart and
Openbox/Labwc menu entries; it does not document a supported API for adding
custom buttons to the left Selkies controller panel. This image therefore does
not inject a custom app switcher into that panel.

Keyboard switching may work when the browser passes the keys through:

- `Alt+Tab` / `Shift+Alt+Tab` for the normal Linux window switcher.

On macOS, `Cmd+Tab` switches your local Mac apps before the key reaches Selkies.
If keyboard capture is unreliable, use the Openbox/Labwc desktop menu or launch
the app from the terminal.

### Gateway

Registered at `/run/service/gateway-default/` on boot. The slot is **never marked
down**. `./setup-hermes-env` creates `.hermes/.env` in the selected
`HERMES_CONFIG_VOLUME` before the container starts, so the gateway can start
immediately without any interactive container setup.

Verify:

```bash
ls -la /run/service/gateway-default/
test -f /config/.hermes/.env && echo "configured" || echo "run hermes setup first"
curl -s -o /dev/null -w "gateway %{http_code}\n" http://127.0.0.1:8642/health
tail -20 /config/.hermes/logs/gateways/default/current
hermes gateway status
```

Manual kick (inside container):

```bash
source /defaults/hermes-s6-lib.sh && hermes_start_slot gateway-default
```

### Dashboard (`HERMES_DASHBOARD=1`)

Registered at `/run/service/hermes-dashboard/` by `21-reconcile-dashboard`, started
after the gateway responds on `:8642`.

Verify:

```bash
curl -s -o /dev/null -w "dashboard %{http_code}\n" -u abc:changeme http://127.0.0.1:9119/
tail -20 /config/.hermes/logs/dashboard/current
```

### Smoke checks

The image includes `hermes-smoke-check` for repeatable runtime checks:

```bash
hermes-smoke-check gateway
hermes-smoke-check dashboard
hermes-smoke-check cdp
hermes-smoke-check browser-harness
hermes-smoke-check faster-whisper
hermes-smoke-check all
```

From the host, after the container is running:

```bash
scripts/smoke.sh gateway
scripts/smoke.sh all
```

The Compose healthcheck uses the gateway check because Brave/CDP only becomes
available after the desktop session starts.

### Backup and restore

For "continue where it left off" backups, save the configured `/config` host
directory. In local mode that is usually `./data`; in server mode it is the path
stored in `HERMES_CONFIG_VOLUME`.

Use the included incremental backup script:

```bash
scripts/backup.sh
```

By default it:

- stops the configured container briefly, then restarts it after the snapshot
- creates a timestamped snapshot under `HERMES_BACKUP_DIR` or `./backups`
- updates `backups/latest-lean`
- keeps Hermes auth/config/databases, skills, Browser Harness state, Obsidian
  files, and Brave profile/session state
- skips bulky regenerable caches and logs such as `.cache`, `.npm`,
  `.hermes/logs`, Brave cache directories, Safe Browsing databases, and component
  update caches
- skips runtime-only sockets, device files, and browser lock files that cannot be
  restored usefully

Later lean backups use hard links against the previous snapshot, so they are much
faster and usually much smaller while still looking like complete backup folders.

Useful variants:

```bash
scripts/backup.sh --zip
scripts/backup.sh --full
scripts/backup.sh --live
scripts/backup.sh --config-dir /srv/hermes-docker/config
scripts/backup.sh --backup-dir /secure/hermes-backups
```

`--zip` also writes a portable archive such as
`backups/20260720T120000Z-lean.zip` and updates `backups/latest-lean.zip`. This
is convenient for Google Drive, S3, or moving state between servers. The local
rsync snapshots are incremental through hard links; a zip archive is portable but
is a full lean backup each time you upload it.

`--full` copies everything in `/config`. `--live` avoids stopping the container,
but SQLite databases and browser state may be mid-write.

Restore the latest lean snapshot:

```bash
scripts/restore.sh
```

Restore a specific snapshot without prompting:

```bash
scripts/restore.sh ./backups/20260720T120000Z-lean --yes
```

Restore from a portable zip:

```bash
scripts/restore.sh ./backups/20260720T120000Z-lean.zip --yes
```

Restore stops and restarts the configured container by default, syncs the backup
into `HERMES_CONFIG_VOLUME`, and deletes files in the target that are not present
in the snapshot. Backups contain cookies, OAuth tokens, API keys, and agent
memory; store them encrypted.

| Mode | How | Notes |
| --- | --- | --- |
| X11 (default) | `PIXELFLUX_WAYLAND=false` | Widest compatibility, CPU encode |
| Wayland | `PIXELFLUX_WAYLAND=true` | Smithay + Labwc, zero-copy GPU encode |

Wayland mode requires an AVX2-capable CPU; on CPUs without AVX2 the base image
**auto-falls-back to X11**. For GPU encode/render in Wayland mode, expose a GPU:

```bash
# Intel / AMD
docker run ... --device /dev/dri -e PIXELFLUX_WAYLAND=true -e AUTO_GPU=true hermes-docker
# NVIDIA (needs the nvidia container runtime on the host)
docker run ... --gpus all --runtime nvidia -e PIXELFLUX_WAYLAND=true -e AUTO_GPU=true hermes-docker
```

(Compose: uncomment the `devices:` / `deploy:` blocks in `docker-compose.yml`.)

## Configuration

| Env var | Default | Description |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | current folder from setup wizard | Compose project/network prefix for this instance |
| `HERMES_CONTAINER_NAME` | current folder from setup wizard | Docker container name for this instance |
| `COMPOSE_PROFILES` | `server` from setup wizard | `server` = no direct host ports, `local` = publish local ports |
| `HERMES_CONFIG_VOLUME` | external path for `server`, `./data` for `local` | Host path mounted as `/config`; contains secrets and browser state |
| `HERMES_BACKUP_DIR` | `./backups` | Host path for incremental backup snapshots |
| `HERMES_REVERSE_PROXY_NETWORK` | `hermes-edge` | External network name used by `docker-compose.server.yml` |
| `HERMES_DESKTOP_HTTPS_HOST_PORT` | `3001` | Published host port for Selkies HTTPS |
| `HERMES_DESKTOP_HTTP_HOST_PORT` | `3000` | Published host port for Selkies HTTP |
| `HERMES_GATEWAY_HOST_PORT` | `8642` | Published host port for the Hermes gateway |
| `HERMES_DASHBOARD_HOST_PORT` | `9119` | Published host port for the dashboard |
| `PASSWORD` | `changeme` | Desktop HTTP basic-auth password (**change it**) |
| `CUSTOM_USER` | `abc` | Desktop HTTP basic-auth username |
| `TITLE` | `Hermes Desktop` | Browser tab title for the desktop |
| `PIXELFLUX_WAYLAND` | `false` | `true` = Wayland, `false` = X11 |
| `AUTO_GPU` | unset | `true` to auto-pick the first GPU (Wayland) |
| `PUID` / `PGID` | `1000` | User/group ids for the `abc` user |
| `HERMES_DASHBOARD` | `1` in compose | Set to `1` to enable the web dashboard on port `9119` |
| `HERMES_DASHBOARD_HOST` | `0.0.0.0` | Dashboard bind address |
| `HERMES_DASHBOARD_PORT` | `9119` | Dashboard HTTP port |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `abc` | Login user (required for `0.0.0.0` bind) |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | `changeme` | Login password (**change it**) |

### Hermes setup wizard

Run `./setup-hermes-env` on the host before `docker compose up`. The script keeps
Docker-specific setup small, builds `hermes-docker` if it is missing, then runs
Hermes' own setup wizard inside the image with `HERMES_CONFIG_VOLUME` mounted as
`/config`.

```bash
./setup-hermes-env
docker compose up -d
```

The script:

- writes Compose credentials and dashboard settings to `.env`
- seeds minimal gateway/browser runtime keys in `$HERMES_CONFIG_VOLUME/.hermes/.env`
- seeds browser-enabled Hermes config in `$HERMES_CONFIG_VOLUME/.hermes/config.yaml`
- executes:

  ```bash
  docker run --rm -it \
    -v "<selected-runtime-state-path>:/config" \
    -e HOME=/config \
    -e HERMES_HOME=/config/.hermes \
    --entrypoint hermes \
    hermes-docker setup
  ```

Provider/model/API-key/OAuth choices are handled by Hermes itself. For example,
selecting `openai-codex` uses Hermes' native Codex auth flow and stores the result
under `$HERMES_CONFIG_VOLUME/.hermes` for unattended server startup.

If Docker Desktop reports `You don't have enough free space in
/var/cache/apt/archives/`, keep the default build first. Optional heavy packages
such as `ffmpeg` and `build-essential` are disabled by default; enable them only
when needed:

```bash
docker build --build-arg INSTALL_OPTIONAL_BUILD_TOOLS=true -t hermes-docker .
```

If the default build still fails on a tiny package, Docker Desktop's Linux disk is
full rather than the image step being too large. Check:

```bash
docker system df
```

Free space by deleting unused Docker images/caches, or increase Docker Desktop's
disk image size. The most direct cleanup is:

```bash
docker image prune -a
docker builder prune
```

### Multiple instances

Each checkout can run as its own instance. `./setup-hermes-env` defaults the
Compose project name and container name to the current folder name, then writes
them to `.env`.

```bash
cp -R hermes-agent-docker hermes-work
cd hermes-work
./setup-hermes-env
docker compose up -d
```

Use different published host ports for every instance when prompted, for example
`3101`, `3100`, `8742`, and `9219` for the second copy. The in-container ports
stay `3001`, `3000`, `8642`, and `9119`.

### Telegram (gateway)

The image bakes **`python-telegram-bot==22.8`** into the Hermes venv at build time so
the Telegram gateway adapter can import. Set these in `/config/.hermes/.env` (via
`hermes setup` or by hand), then restart the gateway:

```bash
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=...
source /defaults/hermes-s6-lib.sh && hermes_start_slot gateway-default
```

The default Hermes config lives at `root/defaults/hermes/config.yaml` and is seeded
into `/config/.hermes/config.yaml` on first boot. Edit the seeded file (then
restart) to tweak toolsets or the `browser.cdp_url`.

## Repository layout

```
hermes-docker/
├── Dockerfile                 # base image + Brave + Hermes + config
├── .env.example               # non-secret sample environment
├── docker-compose.yml
├── docker-compose.server.yml  # optional reverse-proxy/VPN network override
├── data/
│   └── README.md              # warning for ignored runtime state
├── root/                      # copied into the image at /
│   ├── custom-cont-init.d/
│   │   ├── 10-hermes-init                 # seeds config, desktop autostart, node symlinks
│   │   ├── 20-reconcile-gateways          # /run/service/gateway-default (abc-owned)
│   │   ├── 21-reconcile-dashboard         # /run/service/hermes-dashboard
│   │   └── 99-cleanup-stale-dynamic-slots # removes old brave-browser slot only
│   ├── etc/services.d/
│   │   └── hermes-start/                  # rescan + start gateway/dashboard slots
│   ├── usr/local/bin/
│   │   └── hermes-smoke-check             # in-container smoke checks
│   ├── defaults/
│   │   ├── gateway-default/               # template for /run/service slot
│   │   ├── hermes-dashboard/
│   │   ├── launch-desktop.sh
│   │   ├── autostart                      # calls launch-desktop.sh
│   │   ├── autostart_wayland
│   │   ├── menu.xml
│   │   ├── menu_wayland.xml
│   │   └── hermes/config.yaml
├── scripts/
│   ├── backup.sh              # incremental /config snapshots
│   ├── restore.sh             # restore a backup snapshot
│   └── smoke.sh               # host wrapper for hermes-smoke-check
└── README.md
```

## Security

Selkies basic-auth is *"keep the kids out"*, not internet-grade. For anything
exposed beyond a trusted network:

- Put it behind a reverse proxy with real TLS + auth (e.g. LinuxServer SWAG).
- Lock down the EC2 security group to your IP.
- **Never** expose the Selkies control port `8083` or the gateway `8642` publicly
  without your own authentication layer.
- Prefer the `server` profile for remote hosts; it publishes no host ports and
  expects access through a reverse proxy, VPN, or SSH tunnel.
- Keep `HERMES_CONFIG_VOLUME` encrypted or on a protected server path. It contains
  browser cookies, OAuth tokens, API keys, and agent memory.
- Brave runs with `--no-sandbox` and Compose uses `seccomp:unconfined` because
  this headed desktop stack needs them in Docker. The service is not privileged
  and does not use host networking; keep it isolated behind your edge controls.

## Notes / tradeoffs

- The image is large (full desktop stack + Brave + Hermes' bundled Python/Node/
  Playwright). That's the cost of an all-in-one; you could later split Hermes into a
  sidecar container if size matters.
- The Selkies base image is pinned by digest for reproducible builds. The Hermes
  upstream installer is still fetched from the official installer URL because it
  does not currently expose a pinned release artifact in this repo; use the smoke
  checks after rebuilding.
- `ffmpeg` and `build-essential` are optional to keep the default image buildable
  on tighter Docker Desktop disks. Rebuild with
  `--build-arg INSTALL_OPTIONAL_BUILD_TOOLS=true` if you need local media/TTS
  tooling or native package compilation inside the image.
- Hermes also ships a Playwright Chromium fallback, but this setup intentionally
  drives the **visible Brave** via CDP so you can watch (and take over) the session.
