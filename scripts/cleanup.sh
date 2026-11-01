#!/usr/bin/env bash
#
# Remove what interrupted jobs leave behind: job containers that are not
# running, the job volumes no container holds, and job images a re-pull has
# untagged or a newer image has replaced.
#
# The quadlet runs this before every start of the runner. The runner tears down
# only the jobs it sees end, and its idle cleanup cannot remove a volume a
# container still holds (it logs a warning on every pass instead), so a job cut
# off by a shutdown would otherwise stay on disk.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/cleanup.sh [--dry-run] [-h|--help]

Remove the containers and volumes of jobs that were cut off (a shutdown, a
crash), and the untagged copies of every job image that carries the
gitea-act-runner.job-image label but the newest of its repository. Refuses
while the runner is running; the service runs it by itself before every start.

Options:
  --dry-run   List what would be removed, without removing it.
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

PREFIX="GITEA-ACTIONS-TASK-"   # the runner's name prefix for job containers and volumes
# The label of job-image.Containerfile's image, and of any image a workflow
# builds for its own jobs that wants the same treatment.
JOB_IMAGE_LABEL="gitea-act-runner.job-image=true"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
# remove <what> <command...>: run the command quietly, or only name <what> on a dry run.
remove() {
  local what="$1"; shift
  if [ "$DRY" -eq 1 ]; then printf '\033[1;36m[dry-run]\033[0m would remove %s\n' "$what"; return; fi
  say "Removing $what"
  "$@" >/dev/null
}

# A live runner creates a job's volumes before its container, and the container
# before starting it, so either can look abandoned while the job is being set up.
if [ "$(podman container inspect gitea-runner --format '{{.State.Running}}' 2>/dev/null)" = "true" ]; then
  die "The runner is running. Stop it first: systemctl --user stop gitea-runner.service"
fi

containers="$(podman ps -a --format '{{.Names}} {{.State}}' \
  | awk -v p="$PREFIX" 'index($1, p) == 1 && $2 != "running" { print $1 }')"
for name in $containers; do
  remove "job container $name" podman rm -f -v "$name"
done

# A dry run removed no container, so the volumes those still hold are listed too.
if [ "$DRY" -eq 1 ]; then
  volumes="$(podman volume ls --format '{{.Name}}' | grep "^$PREFIX" || true)"
else
  volumes="$(podman volume ls --filter dangling=true --format '{{.Name}}' | grep "^$PREFIX" || true)"
fi
for name in $volumes; do
  remove "job volume $name" podman volume rm "$name"
done

# Labelled job images: of each repository the newest stays, and so does every
# tagged one; the older untagged copies go. They are told apart by the
# repository of their registry digest, which an image keeps after its tag moves
# on and which is all a workflow's image pulled by digest has. Creation times
# print in UTC, so they sort as text.
kept=" "
while read -r _ _ _ _ id tags digest; do
  repository="${digest%@*}"
  [ -n "$repository" ] || continue          # no registry digest: nothing to group it by
  case "$kept" in
    *" $repository "*)
      [ "$tags" -eq 0 ] || continue
      remove "replaced job image $repository ($id)" podman rmi "$id" || say "Kept $id: podman could not remove it" ;;
    *) kept="$kept$repository " ;;
  esac
done < <(for id in $(podman images --filter "label=$JOB_IMAGE_LABEL" --format '{{.ID}}' | sort -u); do
           podman image inspect --format '{{.Created}} {{.Id}} {{len .RepoTags}} {{index .RepoDigests 0}}' "$id" 2>/dev/null || true
         done | sort -r)

say "Done."
