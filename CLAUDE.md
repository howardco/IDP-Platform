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
