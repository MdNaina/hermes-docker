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
- **X11 / Wayland:** handled by the base image's `PIXELFLUX_WAYLAND` env var — no
  custom plumbing. Brave is launched with `--ozone-platform-hint=auto` so the same
  image renders correctly in either mode.

## Quick start

### With Docker Compose

```bash
# 1. Generate .env, data/.hermes/.env, and data/.hermes/config.yaml.
#    If the image is missing, the script builds hermes-docker first.
./setup-hermes-env

# 2. Start the server
docker compose up -d --build

# 3. Open the desktop and log in with the credentials from the wizard
#    https://<host-ip>:3001     (self-signed cert -> accept the warning)
```

### With plain docker run

```bash
docker build -t hermes-docker .

docker run -d --name hermes-docker \
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

- `.env` for Docker Compose credentials, bind address, and dashboard settings
- `data/.hermes/.env` for Hermes gateway/API secrets, provider keys, and
  Telegram or Slack tokens
- `data/.hermes/config.yaml` for the selected provider/model and browser config

If you leave the desktop password blank, the wizard generates one and prints it
before starting Hermes' native setup flow. Dashboard login uses the same password
unless you enter a separate dashboard password.

The container then starts unattended: the **gateway API** starts on `:8642`, the
**dashboard Web UI** starts on `:9119`, and the visible Brave session is
available when you open the Selkies desktop. `http://localhost:8642/` may return
`404`; use `http://localhost:8642/health` for the gateway health check.

With a Nous Portal subscription, the wizard can write the model choice, but OAuth
still requires a browser login. Run `hermes setup --portal` once from the desktop
if `data/.hermes/auth.json` is not already present.

Start chatting in the terminal with `hermes`, and ask it to browse — its actions
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

### Gateway

Registered at `/run/service/gateway-default/` on boot. The slot is **never marked
down**. `./setup-hermes-env` creates `data/.hermes/.env` before the container
starts, so the gateway can start immediately without any interactive container
setup.

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
Hermes' own setup wizard inside the image with `data/` mounted as `/config`.

```bash
./setup-hermes-env
docker compose up -d
```

The script:

- writes Compose credentials and dashboard settings to `.env`
- seeds minimal gateway/browser runtime keys in `data/.hermes/.env`
- seeds browser-enabled Hermes config in `data/.hermes/config.yaml`
- executes:

  ```bash
  docker run --rm -it \
    -v "$PWD/data:/config" \
    -e HOME=/config \
    -e HERMES_HOME=/config/.hermes \
    --entrypoint hermes \
    hermes-docker setup
  ```

Provider/model/API-key/OAuth choices are handled by Hermes itself. For example,
selecting `openai-codex` uses Hermes' native Codex auth flow and stores the result
under `data/.hermes` for unattended server startup.

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
├── docker-compose.yml
├── root/                      # copied into the image at /
│   ├── custom-cont-init.d/
│   │   ├── 10-hermes-init                 # seeds config, desktop autostart, node symlinks
│   │   ├── 20-reconcile-gateways          # /run/service/gateway-default (abc-owned)
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
- `ffmpeg` and `build-essential` are optional to keep the default image buildable
  on tighter Docker Desktop disks. Rebuild with
  `--build-arg INSTALL_OPTIONAL_BUILD_TOOLS=true` if you need local media/TTS
  tooling or native package compilation inside the image.
- Hermes also ships a Playwright Chromium fallback, but this setup intentionally
  drives the **visible Brave** via CDP so you can watch (and take over) the session.
