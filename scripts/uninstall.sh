#!/usr/bin/env bash
#
# Stop and remove the Gitea Actions runner.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [--purge] [-h|--help]

Stop and remove the Gitea Actions runner (service + quadlet + container).

Options:
  --purge     Also delete data/.runner (loses the registration; then delete the
              runner in the Gitea admin UI too).
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
QUADLET_DST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/gitea-runner.container"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }

say "Stopping $SERVICE…"
systemctl --user stop "$SERVICE" 2>/dev/null || true

say "Removing quadlet: $QUADLET_DST"
rm -f "$QUADLET_DST"
systemctl --user daemon-reload
podman rm -f gitea-runner 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
  say "--purge: deleting data/.runner (the registration is lost)."
  rm -f "$REPO_DIR/data/.runner"
  warn "Also delete this runner from the Gitea admin UI (Runners list)."
fi

say "Done."
