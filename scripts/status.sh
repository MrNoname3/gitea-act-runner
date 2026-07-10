#!/usr/bin/env bash
# Show the runner service + container status.
set -euo pipefail
systemctl --user --no-pager status gitea-runner.service || true
echo
podman ps --filter name=gitea-runner --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
