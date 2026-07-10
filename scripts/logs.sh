#!/usr/bin/env bash
# Follow the runner logs. Optional arg: number of tail lines (default 50).
set -euo pipefail
exec podman logs -f --tail "${1:-50}" gitea-runner
