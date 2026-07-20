# Runtime Data

This directory is the default `/config` volume for local development. It is
mostly ignored by Git because it contains private, high-value runtime state:

- `data/.hermes/.env`: API keys, gateway secrets, provider tokens.
- `data/.hermes/auth.json`: OAuth/session credentials.
- `data/.brave/`: browser cookies, history, saved sessions, and profile data.

For a remote server, prefer an encrypted host path outside this repository, for
example `/srv/hermes-docker/config` or `$HOME/.local/share/hermes-docker`, and set
`HERMES_CONFIG_VOLUME` in `.env`.

Back up this directory only to encrypted storage. Do not commit it, include it in
Docker build context, or publish it in support bundles.

Use `scripts/backup.sh` for fast incremental backups and `scripts/restore.sh` to
restore the latest lean snapshot.
