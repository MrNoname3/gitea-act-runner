#!/usr/bin/env bash
# Release gate — the single entry point for every repo check.
#
#   ./scripts/check.sh
#
# CI (.github/workflows/ci.yml) runs exactly this script, so a local pass means
# a CI pass. Steps:
#   1. toolchain     — scripts/ensure-venv.sh: linters pinned in requirements.txt,
#                      in the gitignored .venv/
#   2. shellcheck    — scripts/*.sh
#   3. yamllint      — the config template and the workflows
#   4. rendered config — the template rendered as setup.sh does, with and without
#                      resource limits, so a template edit that yields invalid
#                      YAML only after substitution is caught
#   5. secret scan   — tracked files only; generic patterns below, plus optional
#                      private patterns from .secret-patterns.local (gitignored —
#                      put hostnames and other identifiers there, one extended
#                      regex per line, '#' comments allowed)
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=.venv

step() { printf '\n=== %s ===\n' "$1"; }

step "toolchain (.venv)"
./scripts/ensure-venv.sh
"$VENV/bin/shellcheck" --version | sed -n 2p
"$VENV/bin/yamllint" --version

step "shellcheck"
"$VENV/bin/shellcheck" scripts/*.sh

step "yamllint"
"$VENV/bin/yamllint" config.yaml.template .github/workflows/

step "yamllint (rendered config)"
rendered="$(mktemp --suffix=.yaml)"
trap 'rm -f "$rendered"' EXIT
for opts in "--memory=4g --cpus=3" ""; do
  sed -e 's#__CI_RUNNER_CAPACITY__#2#g' \
      -e "s#__CI_CONTAINER_OPTIONS__#${opts}#g" \
      config.yaml.template > "$rendered"
  "$VENV/bin/yamllint" -c .yamllint "$rendered"
done

step "secret scan (tracked files)"
# The repo is mirrored publicly: no machine identifiers may be committed. These
# patterns are deliberately generic — private patterns (own hostnames, ...)
# belong in the untracked .secret-patterns.local, NOT here.
fail=0

scan() { # scan <label> <pattern-ERE> [allowlist-ERE]
  local label="$1" pattern="$2" allow="${3:-}" hits
  hits="$(git grep -nEI -e "$pattern" -- ':(exclude)scripts/check.sh' || true)"
  if [ -n "$allow" ] && [ -n "$hits" ]; then
    hits="$(printf '%s\n' "$hits" | grep -vE -- "$allow" || true)"
  fi
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "FAIL: possible secret in tracked files ($label)"
    fail=1
  fi
}

scan "private key block" 'BEGIN [A-Z ]*PRIVATE KEY'
# Allowlisted: 10.89.0.1, the gateway of Podman's default user network, and the
# four-part version pins in requirements.txt.
scan "IPv4 address" '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  '0\.0\.0\.0|127\.0\.[01]\.1|192\.168\.0\.0/16|10\.0\.0\.0/8|172\.16\.0\.0/12|10\.89\.0\.1|^requirements\.txt:[0-9]+:[A-Za-z0-9_.-]+==[0-9.]+$'
scan "MAC address" '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' \
  'aa:bb:cc:dd:ee:ff'
scan "UUID" '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'

if [ -f .secret-patterns.local ]; then
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    scan "local pattern" "$p"
  done < .secret-patterns.local
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Secret scan failed. False positive? Extend the allowlist in scripts/check.sh."
  exit 1
fi
echo "OK"

printf '\nAll checks passed.\n'
