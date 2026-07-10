#!/usr/bin/env bash
#
# Install and start the Gitea Actions runner. Idempotent: safe to re-run.
#
# What it does:
#   - preflight checks (rootless podman + user systemd)
#   - enables user lingering (so the service runs without an active login and
#     starts on boot) and the podman user socket
#   - renders the quadlet with this repo's absolute path and installs it into
#     ~/.config/containers/systemd/
#   - daemon-reload + (re)start, then reports status
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [--dry-run] [-h|--help]

Install and start the Gitea Actions runner as a rootless podman container
managed by a systemd user quadlet. Reads runner.env (copy it from
runner.env.example and fill in the registration token first).

Options:
  --dry-run   Show what would be done, without changing anything.
  -h, --help  Show this help and exit.
EOF
}

DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Repo root = this script's parent directory (resolve symlinks with -P).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

UNIT_NAME="gitea-runner.container"
SERVICE="gitea-runner.service"
QUADLET_SRC="$REPO_DIR/$UNIT_NAME"
QUADLET_DST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
QUADLET_DST="$QUADLET_DST_DIR/$UNIT_NAME"
ENV_FILE="$REPO_DIR/runner.env"
DATA_DIR="$REPO_DIR/data"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" -eq 1 ]; then printf '\033[1;36m[dry-run]\033[0m %s\n' "$*"; else "$@"; fi; }

if [ "$DRY" -eq 1 ]; then say "Dry run — no changes will be made."; fi

# 1) Preflight ---------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root — this is a rootless, user-scope setup."
command -v podman    >/dev/null 2>&1 || die "'podman' not found in PATH."
command -v systemctl >/dev/null 2>&1 || die "'systemctl' not found (user systemd is required)."
[ -f "$QUADLET_SRC" ] || die "Quadlet template missing: $QUADLET_SRC"

# 2) runner.env --------------------------------------------------------------
[ -f "$ENV_FILE" ] || die "runner.env is missing. Create it:  cp runner.env.example runner.env  then edit it."

# 3) Data dir (holds the .runner registration state) -------------------------
run mkdir -p "$DATA_DIR"

# 4) Token check — only required for the FIRST registration ------------------
if [ ! -f "$DATA_DIR/.runner" ]; then
  TOKEN="$(grep -E '^GITEA_RUNNER_REGISTRATION_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "REPLACE_WITH_REGISTRATION_TOKEN" ]; then
    die "Set GITEA_RUNNER_REGISTRATION_TOKEN in runner.env (needed for first registration). See README.md."
  fi
  say "First run: the runner will register using the token."
else
  say "Already registered (data/.runner exists) — no token needed."
fi

# 5) Lingering (run without an active login; start on boot) ------------------
if [ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null || echo no)" != "yes" ]; then
  say "Enabling lingering for '$USER'…"
  run loginctl enable-linger "$USER" \
    || warn "Could not enable lingering. Run manually: sudo loginctl enable-linger $USER"
fi

# 6) Podman user socket (the runner starts job containers via %t/podman/podman.sock)
run systemctl --user enable --now podman.socket \
  || warn "Could not enable podman.socket — check: systemctl --user status podman.socket"

# 7) Render + install the quadlet -------------------------------------------
say "Installing quadlet -> $QUADLET_DST"
if [ "$DRY" -eq 1 ]; then
  printf '\033[1;36m[dry-run]\033[0m render %s (__CI_RUNNER_DIR__=%s) -> %s\n' "$QUADLET_SRC" "$REPO_DIR" "$QUADLET_DST"
else
  mkdir -p "$QUADLET_DST_DIR"
  sed "s#__CI_RUNNER_DIR__#${REPO_DIR}#g" "$QUADLET_SRC" > "$QUADLET_DST"
fi

# 8) Reload systemd + (re)start ---------------------------------------------
run systemctl --user daemon-reload
say "Starting $SERVICE"
run systemctl --user restart "$SERVICE"

# 9) Verify ------------------------------------------------------------------
if [ "$DRY" -eq 1 ]; then
  say "Dry run complete. Re-run without --dry-run to apply."
  exit 0
fi

sleep 5
if systemctl --user is-active --quiet "$SERVICE"; then
  say "$SERVICE is active."
else
  warn "$SERVICE is not active. Status:"
  systemctl --user --no-pager status "$SERVICE" || true
  die "Runner failed to start. Check the logs above."
fi

echo
say "Recent runner log:"
podman logs --tail 12 gitea-runner 2>&1 || true
echo
say "Done. Verify in Gitea: Site Administration -> Actions -> Runners (green = online)."
