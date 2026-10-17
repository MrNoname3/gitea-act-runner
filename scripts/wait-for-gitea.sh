#!/usr/bin/env bash
#
# Wait, for at most a minute, until the hostname of GITEA_INSTANCE_URL in
# runner.env resolves.
#
# The quadlet runs this before every start of the runner. At boot a user service
# can start before the host's network is up; Podman 5 waits for it, Podman 4
# does not. The runner would then retry by itself, but only every 30 seconds,
# and with a warning in the log at every boot.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="$SCRIPT_DIR/../runner.env"
TIMEOUT=60

url="$(grep -E '^GITEA_INSTANCE_URL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
host="${url#*://}"
host="${host%%[/:]*}"
[ -n "$host" ] || exit 0

while ! getent hosts "$host" >/dev/null; do
  if [ "$SECONDS" -ge "$TIMEOUT" ]; then
    printf '%s does not resolve after %ss; starting the runner anyway.\n' "$host" "$TIMEOUT" >&2
    exit 0
  fi
  sleep 1
done
