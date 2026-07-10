#!/usr/bin/env bash
#
# Stop and remove the Gitea Actions runner.
#   ./uninstall.sh           stop + remove the unit (keeps data/.runner)
#   ./uninstall.sh --purge   also delete data/ (loses the registration)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

UNIT_NAME="gitea-runner.container"
SERVICE="gitea-runner.service"
QUADLET_DST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/$UNIT_NAME"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say "Stopping $SERVICE…"
systemctl --user stop "$SERVICE" 2>/dev/null || true

say "Removing quadlet: $QUADLET_DST"
rm -f "$QUADLET_DST"
systemctl --user daemon-reload
podman rm -f gitea-runner 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
  say "--purge: deleting data/ (the runner registration is lost)."
  rm -f "$REPO_DIR/data/.runner"
  warn "Also delete this runner from the Gitea admin UI (Runners list)."
fi

say "Done."
