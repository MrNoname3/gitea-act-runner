# gitea-act-runner — notes for coding agents

The README covers installing and operating the runner. What follows is what an
agent working on this repository needs and cannot read off the files.

## Generated files: edit the source, then run setup.sh

`config.yaml` and the installed quadlet
(`~/.config/containers/systemd/gitea-runner.container`) are rendered by
`scripts/setup.sh` from `config.yaml.template`, `gitea-runner.container` and
`runner.env`. Edit those, never the output.

Running `setup.sh` restarts the runner, and a restart cancels every job in
progress on it. Check that nothing is running first: while a job runs,
`podman ps` lists a `GITEA-ACTIONS-TASK-*` container.

The checkout's absolute path is baked into the installed quadlet. After moving
the checkout, run `setup.sh` from the new location; until then the service
still points at the old one.

## Secrets, and a public mirror

`runner.env` holds the registration token and `data/.runner` the runner's
identity. Never print, paste or commit either. To read one setting, read that
key alone, as `setup.sh`'s `read_env` does, not the whole file.

The repository is mirrored to a public GitHub repository. No private hostname,
IP address, username or absolute home path goes into a commit, a comment or a
document; examples use placeholders such as `gitea.example.com`.

## A failed job is often the runner, not the workflow

Build results are not in the working tree; ask the forge's Actions API (with
the `gitea` skill installed: `gitea-api ci`, `gitea-api ci log`).

The runner host is part of every build. When a job fails at "Set up job", or at
its first `uses:` step before any of the workflow's own commands ran, look at
the host first: whether `gitea-runner.service` is active, which Podman and
Buildah versions are installed, what `scripts/logs.sh` shows. The README's
Troubleshooting section lists the known failure signatures.

Several runners can serve the same label, and the server hands each job to
whichever is free, so a job may have run on another machine; the job's
`runner_name` in the Actions API says which.

Podman and systemctl act on the host's user session. From a sandboxed shell (a
Flatpak editor's terminal, a toolbox) they can be missing or reach a different
instance, so get to the host before concluding the runner is down.

## Resource limits: measure before changing them

`CI_JOB_MEMORY`, `CI_JOB_CPUS` and `CI_RUNNER_CAPACITY` are set from observed
usage, not estimates. To size them, start a representative heavy workflow with
`workflow_dispatch`, sample `podman stats --no-stream` for the
`GITEA-ACTIONS-TASK-*` containers every ten seconds or so until it finishes,
and watch the host's load average alongside. Compare each job's peak with the
caps, and the run's duration with the jobs' `timeout-minutes`.

To measure one machine while other runners share its label, stop the others
for the duration, or the jobs may land on them instead.

## Commits

Subject `<area>: <summary>` in lower case (`runner:`, `ci:`, `docs:`,
`renovate:`, `editor:`), with the body saying why. Add `[skip ci]` only when
the change cannot affect what `.github/workflows/lint.yml` checks: the
scripts, the config template and the workflows. Before pushing, run the same
shellcheck and yamllint commands that workflow runs.

## English

Everything here is written in English, comments included, whatever language
the conversation is held in.
