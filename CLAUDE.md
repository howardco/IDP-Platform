# CLAUDE.md

Guidance for Claude Code when installing or operating this stack via
`claude https://github.com/howardco/IDP-Platform`.

## Do not touch host-level network configuration

Never edit, in service of "fixing" connectivity, debugging, or any other
goal during install or operation of this stack:

- `/etc/hosts` (or Windows/WSL equivalents)
- Firewall rules (`pf`, `iptables`, `ufw`, etc.)
- `sshd_config` or any SSH daemon configuration
- The Docker daemon's bind address or `daemon.json`
- Any OS-level network interface or routing configuration

All of this stack's services are published via Docker Compose `ports:`
entries in `docker-compose.yml` using the plain `"HOST:CONTAINER"` form
(e.g. `"8084:8084"`), which Docker binds to `0.0.0.0` by default — reachable
from other machines on the network, not just `localhost`. If a service
seems unreachable from another machine, the fix is almost never host
network config: check the compose file's `ports:` mapping first, then
firewall *state* (read-only), then ask the user before changing anything
outside this repo and its sibling repos under `~/CODE/IDP/`.

If a change to host-level config genuinely seems required, stop and ask
the user explicitly — do not make the change and revert it unprompted,
and do not make it at all without confirmation first, even temporarily.

## Secrets

Only two values need setting in `.env`: `OPENAI_API_KEY` and
`SERPER_API_KEY`. Everything else (DB credentials, internal service URLs,
Superset's secret key, etc.) ships with working defaults in
`docker-compose.yml` for this isolated-network, single-machine deployment —
do not invent, "harden", or change any of those defaults during install.
`.env` is gitignored; never commit it, and never echo its contents (or any
secret value) back to the user in chat.

## Build and startup order

1. `./build.sh` — builds `idp-shared-libs:latest` first (the three internal
   libraries, IDP-MCP-Enhancer/IDP-StockApiClient/IDP-Strategy-Model, must
   exist as that image before any consuming service's own Dockerfile can
   `COPY --from=idp-shared-libs:latest`), then every service image.
2. `docker compose up -d`
3. `docker compose ps` — wait for every service to report healthy before
   concluding anything is broken. MySQL, OpenSearch, and Superset in
   particular take real time to become healthy on first start; a service
   stuck in `starting` for a minute or two after `up -d` is normal, not a
   failure. Only investigate once `ps` shows `unhealthy` or the container
   has exited.
4. Verify using the table in README.md's "Verification" section, in that
   order (actuator health endpoints first, then the UI/demo links).

## Known first-run behavior

- `build_dashboard.py` (in `IDP-Tools/Docker/superset2`, run by the
  `superset-dashboards` container on every `docker compose up`) is
  idempotent: on the first run it creates Superset's datasets, charts, and
  dashboard; on every subsequent run it should exit 0 and log each
  dataset/chart as "already exists" (or "SQL changed, updated" if the
  script's SQL constants changed since the dataset was created). Seeing it
  run more than once across multiple `up`s is expected, not a bug.
- `strategy_execution`, `analyst_response`, and `trade_recommendation`
  datasets expose their execution-UID column as `strategy_execution_uid`
  via virtual-dataset SQL aliasing inside `build_dashboard.py` itself
  (fixed 2026-11-25 — previously this aliasing only existed by hand in one
  instance's Superset metadata and a fresh install's dashboard failed with
  "Columns missing: strategy_execution_uid"). If that error reappears,
  the fix belongs in `build_dashboard.py`'s dataset registration, not in
  MySQL/Java code, and not as a manual edit in Superset's UI.

## Troubleshooting order

When something looks broken, in this order:
1. `docker compose ps` and `docker compose logs <service>` for the
   specific failing service.
2. That service's own repo (its README.md and CLAUDE.md, if present) —
   each sibling repo under `~/CODE/IDP/` owns its own specifics.
3. Only then consider changing `docker-compose.yml` or any service's
   source — and never host-level config (see above).

Do not jump straight to editing compose files, Dockerfiles, or application
source to make a startup-order or timing issue disappear; most first-run
symptoms are explained by the startup order and known behavior above.
