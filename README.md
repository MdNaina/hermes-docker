# hermes-docker

A single Docker image that bundles a **web-native Linux desktop**, a **headed Brave**
browser the **[Hermes agent](https://hermes-agent.nousresearch.com/)** drives live over
CDP, and the **Hermes gateway** (WebUI / messaging) — built on the
[LinuxServer Selkies base image](https://docs.linuxserver.io/images/docker-baseimage-selkies/).

You log in through your browser, watch the agent click and type in a real Brave
window, and optionally chat with the same agent from anywhere via the gateway.
**X11 and Wayland are switchable with a single environment variable.**

## What's inside

| Component | Purpose | Port |
| --- | --- | --- |
| Selkies | Web-native desktop streamed to your browser | `3001` (https), `3000` (http) |
| Brave | Headed browser launched with `--remote-debugging-port=9222` | (internal `9222`, loopback only) |
| Hermes CLI | `hermes` running in an `xterm` inside the desktop | - |
| Hermes gateway | `hermes gateway run` (WebUI / Telegram / Discord) | `8642` |
| Hermes dashboard | Web UI (`HERMES_DASHBOARD=1`, starts after gateway) | `9119` |

```
You (browser)
  │  https :3001  ───────────────►  Selkies desktop  ──►  Brave (headed)
  │  http  :8642  ───────────────►  Hermes gateway        ▲   ▲
  │  http  :9119  ───────────────►  Hermes dashboard      │   │ CDP 127.0.0.1:9222
                                    hermes CLI (xterm) ───┘───┘
```

## Architecture notes

- **Persistence:** in the Selkies base the `hermes` user's `$HOME` is `/config`, and
  `/config` is replaced by the mounted volume at runtime. So the Hermes **code** is
  baked into `/opt/hermes` (ships in the image) while `HERMES_HOME=/config/.hermes`
  keeps **config / API keys / memory** in the persistent volume.
- **Browser control:** Brave starts headed in the desktop with remote debugging on
  loopback `9222`; Hermes attaches via `browser.cdp_url` so every `browser_*` action
  is visible in the desktop you log into.
- **X11 / Wayland:** handled by the base image's `PIXELFLUX_WAYLAND` env var — no
  custom plumbing. Brave is launched with `--ozone-platform-hint=auto` so the same
  image renders correctly in either mode.

## Quick start

### With Docker Compose

```bash
# 1. Change the password in docker-compose.yml first!
docker compose up -d --build

# 2. Open the desktop and log in (user: hermes / pass: changeme)
#    https://<host-ip>:3001     (self-signed cert -> accept the warning)
```

### With plain docker run

```bash
docker build -t hermes-docker .

docker run -d --name hermes-docker \
  --shm-size=2gb \
  --security-opt seccomp=unconfined \
  -p 3001:3001 -p 8642:8642 -p 9119:9119 \
  -e CUSTOM_USER=hermes \
  -e PASSWORD=changeme \
  -e TITLE="Hermes Desktop" \
  -e PIXELFLUX_WAYLAND=false \
  -e HERMES_DASHBOARD=1 \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=hermes \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=changeme \
  -v "$PWD/data:/config" \
  hermes-docker
```

## First-run setup (configure the LLM backend)

No API keys are baked in — pick your provider once and it persists in the volume.

1. Open `https://<host-ip>:3001` and log in.
2. The desktop opens with a **Hermes terminal** (and a Brave window). In that
   terminal run the wizard:

   ```bash
   hermes setup            # choose any provider + API key
   # or, with a Nous Portal subscription (one OAuth covers model + tools):
   hermes setup --portal
   ```

3. Once setup writes `/config/.hermes/.env`, the **gateway** auto-starts (s6 service
   `gateway-default`) and the WebUI becomes reachable at `http://<host-ip>:8642`.
   With `HERMES_DASHBOARD=1`, the **dashboard** starts on `:9119` after the gateway is up.
4. Start chatting in the terminal with `hermes`, and ask it to browse — its actions
   appear live in the Brave window. (In the CLI you can also run `/browser status`
   to confirm the CDP connection, or `/browser connect` to attach manually.)

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

### Gateway

Registered at `/run/service/gateway-default/` on boot. The slot is **never marked
down** — the run script waits for `/config/.hermes/.env`, then starts. If you run
`hermes setup` after the container is already up, opening the Selkies desktop also
triggers a gateway start.

Verify:

```bash
ls -la /run/service/gateway-default/
test -f /config/.hermes/.env && echo "configured" || echo "run hermes setup first"
curl -s -o /dev/null -w "gateway %{http_code}\n" http://127.0.0.1:8642/
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
curl -s -o /dev/null -w "dashboard %{http_code}\n" -u hermes:changeme http://127.0.0.1:9119/
tail -20 /config/.hermes/logs/dashboard/current
```

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
| `PASSWORD` | `changeme` | Desktop HTTP basic-auth password (**change it**) |
| `CUSTOM_USER` | `hermes` | Desktop HTTP basic-auth username |
| `TITLE` | `Hermes Desktop` | Browser tab title for the desktop |
| `PIXELFLUX_WAYLAND` | `false` | `true` = Wayland, `false` = X11 |
| `AUTO_GPU` | unset | `true` to auto-pick the first GPU (Wayland) |
| `PUID` / `PGID` | `1000` | User/group ids for the `hermes` user |
| `HERMES_DASHBOARD` | `1` in compose | Set to `1` to enable the web dashboard on port `9119` |
| `HERMES_DASHBOARD_HOST` | `0.0.0.0` | Dashboard bind address |
| `HERMES_DASHBOARD_PORT` | `9119` | Dashboard HTTP port |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `hermes` | Login user (required for `0.0.0.0` bind) |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | `changeme` | Login password (**change it**) |
| `BRAVE_DISABLE_GPU` | `true` | Set to `false` to let Brave use GPU acceleration (requires `--device /dev/dri` or `--gpus all`) |

### Telegram (gateway)

The image bakes **`python-telegram-bot==22.8`** into the Hermes venv at build time so
the Telegram gateway adapter can import. Set these in `/config/.hermes/.env` (via
`hermes setup` or by hand), then restart the gateway:

```bash
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=...
source /defaults/hermes-s6-lib.sh && hermes_start_slot gateway-default
```

### Slack (Socket Mode)

The image bakes **`slack-sdk==3.40.1`** and **`slack-bolt==1.27.0`** into the Hermes
venv at build time so the Slack gateway adapter (Socket Mode) can import without a
runtime pip install. Set these in `/config/.hermes/.env`:

```bash
SLACK_BOT_TOKEN=xoxb-...          # Bot User OAuth Token
SLACK_APP_TOKEN=xapp-...          # App-Level Token (for Socket Mode)
HERMES_SLACK_ENABLED=true
```

Then generate and install a Slack app manifest:

```bash
# Inside the desktop terminal, generate a manifest with all Hermes
# gateway commands registered as native slash commands:
hermes slack manifest > /config/slack-manifest.yml
```

Create a Slack app at https://api.slack.com/apps using this manifest, install it
to your workspace, copy the tokens into `.env`, and restart the gateway:

```bash
source /defaults/hermes-s6-lib.sh && hermes_start_slot gateway-default
```

Verify:

```bash
hermes gateway status
# Look for "slack: connected" in the output
```

**Note:** Socket Mode requires outbound HTTPS from the container to Slack's
servers — no inbound ports needed. The gateway handles reconnection automatically.

The default Hermes config lives at `root/defaults/hermes/config.yaml` and is seeded
into `/config/.hermes/config.yaml` on first boot. Edit the seeded file (then
restart) to tweak toolsets or the `browser.cdp_url`.

## Repository layout

```
hermes-docker/
├── Dockerfile                 # base image + Brave + Hermes + config
├── docker-compose.yml
├── root/                      # copied into the image at /
│   ├── custom-cont-init.d/
│   │   ├── 10-hermes-init                 # seeds config, desktop autostart, node symlinks
│   │   ├── 20-reconcile-gateways          # /run/service/gateway-default (hermes-owned)
│   │   ├── 21-reconcile-dashboard         # /run/service/hermes-dashboard
│   │   └── 99-cleanup-stale-dynamic-slots # removes old brave-browser slot only
│   ├── etc/services.d/
│   │   └── hermes-start/                  # rescan + start gateway/dashboard slots
│   ├── defaults/
│   │   ├── gateway-default/               # template for /run/service slot
│   │   ├── hermes-dashboard/
│   │   ├── launch-desktop.sh
│   │   ├── autostart                      # calls launch-desktop.sh
│   │   ├── autostart_wayland
│   │   ├── menu.xml
│   │   ├── menu_wayland.xml
│   │   └── hermes/config.yaml
└── README.md
```

## Security

Selkies basic-auth is *"keep the kids out"*, not internet-grade. For anything
exposed beyond a trusted network:

- Put it behind a reverse proxy with real TLS + auth (e.g. LinuxServer SWAG).
- Lock down the EC2 security group to your IP.
- **Never** expose the Selkies control port `8083` or the gateway `8642` publicly
  without your own authentication layer.
- Brave runs with `--no-sandbox` (required in Docker); keep the container itself
  isolated.

## Notes / tradeoffs

- The image is large (full desktop stack + Brave + Hermes' bundled Python/Node/
  Playwright). That's the cost of an all-in-one; you could later split Hermes into a
  sidecar container if size matters.
- Hermes also ships a Playwright Chromium fallback, but this setup intentionally
  drives the **visible Brave** via CDP so you can watch (and take over) the session.

## State portability

All Hermes state lives in the mounted `/config` volume and survives container
recreation. To migrate to a new container (image upgrade, different host, etc.):

1. **Copy the full state** from the old container:
   ```bash
   # From the host running the old container:
   docker cp hermes-docker:/config ./hermes-state-backup
   ```

2. **Start the new container** with that state mounted:
   ```bash
   # Replace ./data with your backup:
   docker run -d --name hermes-docker \
     ...
     -v "$PWD/hermes-state-backup:/config" \
     hermes-docker
   ```

### What survives

| Path | Content | Persists |
|------|---------|----------|
| `/config/.hermes/` | Config, API keys (`.env`), session history, skills, cron jobs, memory, kanban | ✅ Yes |
| `/config/.hermes/sessions/state.db` | All conversation history | ✅ Yes |
| `/config/.hermes/memories/` | Learned user preferences and facts | ✅ Yes |
| `/config/.hermes/skills/` | Custom skill definitions | ✅ Yes |
| `/config/.hermes/cron/` | Scheduled cron jobs | ✅ Yes |
| `/config/.hermes/.env` | API keys for LLM providers and Telegram | ✅ Yes |
| `/config/.hermes/config.yaml` | Hermes runtime configuration | ✅ Yes (not overwritten by init) |
| `/config/.brave/` | Brave browser profile, cookies, login sessions | ✅ Yes |
| `/config/.config/browser-harness/` | Browser-harness daemon state | ✅ Yes |
| `/config/.config/openbox/` or `labwc/` | Desktop autostart and menu | Re-seeded by init |

### What gets recreated

- **Symlinks** (`/config/.hermes/node`, `/config/.hermes/bin`) point to baked paths
  in the image (`/opt/hermes/.hermes/`) — they work automatically on any
  container built from this image.
- **Gateway/Dashboard s6 services** are re-registered by init scripts on each boot.
- **Gateway state** (`gateway_state.json`) is recreated when `.env` is detected.
- **Logs** (`/config/.hermes/logs/`) are rotated by s6-log; old logs are replaced
  on container start.

### Important for new containers

- If you pre-populate `/config/.hermes/.env` with your API keys before first boot,
  the gateway starts automatically — no need to open the desktop and run
  `hermes setup`.
- The `10-hermes-init` script only seeds `config.yaml` if it doesn't already exist,
  so your existing config is preserved.
- **Brave profile** (`/config/.brave/`) carries browser cookies and sessions.
  Without it, the agent starts with a fresh browser — bookmarks and saved logins
  are lost.
