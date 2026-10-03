#!/usr/bin/env bash
#
# Stop and remove the Gitea Actions runner.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [--purge] [-h|--help]

Stop and remove the Gitea Actions runner (service, quadlets, container and
its network).

Options:
  --purge     Also delete data/.runner (loses the registration; then delete the
              runner in the Gitea admin UI too) and the actions cache volume.
  -h, --help  Show this help and exit.
EOF
}

PURGE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --purge)   PURGE=1 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SERVICE="gitea-runner.service"
CACHE_VOLUME="gitea-runner-cache"   # must match the Volume= line in gitea-runner.container
NETWORK="gitea-runner"              # must match NetworkName= in gitea-runner.network
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }

say "Stopping $SERVICE…"
systemctl --user stop "$SERVICE" gitea-runner-network.service 2>/dev/null || true

say "Removing quadlets from $QUADLET_DIR"
rm -f "$QUADLET_DIR/gitea-runner.container" "$QUADLET_DIR/gitea-runner.network"
systemctl --user daemon-reload
podman rm -f gitea-runner 2>/dev/null || true
podman network rm "$NETWORK" >/dev/null 2>&1 || true

if [ "$PURGE" -eq 1 ]; then
  say "--purge: deleting data/.runner (the registration is lost)."
  rm -f "$REPO_DIR/data/.runner"
  warn "Also delete this runner from the Gitea admin UI (Runners list)."
  say "--purge: deleting the $CACHE_VOLUME volume (the actions cache)."
  podman volume rm -f "$CACHE_VOLUME" >/dev/null 2>&1 || true
fi

say "Done."
