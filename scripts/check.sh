#!/usr/bin/env bash
# Release gate — the single entry point for every repo check.
#
#   ./scripts/check.sh
#
# CI (.github/workflows/ci.yml) runs exactly this script, so a local pass means
# a CI pass. The shared steps come from scripts/lib/gate.sh (managed by
# repo-template): the toolchain, shellcheck over every tracked shell script
# and the secret scan, which fails on machine identifiers too, the repository
# being public. This repository's own steps run yamllint over the config
# template and the workflows, and over the template rendered as setup.sh
# renders it, with and without resource limits, so a template edit that
# yields invalid YAML only after substitution is caught.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/gate.sh
. scripts/lib/gate.sh

gate_toolchain
"$VENV/bin/yamllint" --version
gate_shellcheck

step "yamllint"
"$VENV/bin/yamllint" config.yaml.template .github/workflows/

step "yamllint (rendered config)"
rendered="$(mktemp --suffix=.yaml)"
trap 'rm -f "$rendered"' EXIT
for opts in "--memory=4g --cpus=3" ""; do
  sed -e 's#__CI_RUNNER_CAPACITY__#2#g' \
      -e "s#__CI_CONTAINER_OPTIONS__#${opts}#g" \
      -e 's#__CI_JOB_IMAGE__#ghcr.io/owner/act-ubuntu:26.04#g' \
      config.yaml.template > "$rendered"
  "$VENV/bin/yamllint" -c .yamllint "$rendered"
done
echo "OK"

gate_secret_scan
gate_done
