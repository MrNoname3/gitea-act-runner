# gitea-act-runner

Run a **Gitea Actions runner** as a rootless **Podman** container,
managed by a **systemd** user *quadlet* so it survives reboots and starts on its
own. Clone the repo, drop in a registration token, run one script.

The runner uses a **pull model**: it long-polls the server over gRPC (outbound
only), so it works behind NAT/firewall with no inbound port. If the machine is
off when a job is pushed, the job simply queues on the server and runs once the
machine is back and the runner reconnects.

> **Scope / compatibility.** Linux only, with **rootless Podman ≥ 4.7** (quadlet
> support, named networks) and a **systemd user session**. Targets **Gitea**
> Actions (1.21+). Docker and non-systemd setups are out of scope. Developed on
> Podman 5.8 / Fedora-based (SELinux).

---

## How it works

| Piece | Role |
|-------|------|
| `gitea/runner` container | Registers with the server, polls for jobs, launches a job container per job. |
| `config.yaml.template` → `config.yaml` | Runner config. The template is committed; `setup.sh` renders the (gitignored) `config.yaml` from it, filling in the label→image mapping and the **per-machine resource limits**. |
| `runner.env` | Registration inputs (instance URL, token, name), the job image **and per-machine resource limits**. **Secret — gitignored.** |
| `data/.runner` | Registration state written after first start. **Secret — gitignored.** |
| `gitea-runner-cache` volume | The actions cache (`actions/cache`), kept across restarts. |
| `gitea-runner.container` | Quadlet unit template; `scripts/setup.sh` installs it. |
| `gitea-runner.network` | Quadlet unit for the `gitea-runner` network, which the runner and its jobs share. |
| systemd user service + lingering | Auto-start on boot, restart on failure, no login needed. |

Jobs labelled `ubuntu-latest` run in the image `CI_JOB_IMAGE` in `runner.env`
names: the small Ubuntu 26.04 image `job-image.Containerfile` describes (see
[The job image](#the-job-image-ci_job_image)). It brings node, which the runner
needs inside the job container to run JavaScript actions, so a plain `ubuntu`
or a slim `node:*` image is **not** enough.

---

## Prerequisites

- Rootless **Podman ≥ 4.7** (developed on 5.8).
- A **systemd** user session (`systemctl --user` works).
- Permission to enable **lingering** (`loginctl enable-linger <user>`; may need sudo).
- Network access from this machine to the server (a normal HTTPS client).

---

## Quick start

```bash
git clone <this-repo> gitea-act-runner
cd gitea-act-runner

# 1. Provide the registration token and instance settings.
cp runner.env.example runner.env
${EDITOR:-nano} runner.env      # paste GITEA_RUNNER_REGISTRATION_TOKEN, set the name, URL + CI_JOB_IMAGE

# 2. Install + start (idempotent — safe to re-run; add --dry-run to preview).
./scripts/setup.sh
```

Then check **Gitea → Site Administration → Actions → Runners**: the runner should
appear **online (green)** with the `ubuntu-latest` label.

---

## Getting a registration token

**From the web UI (as admin):**
Site Administration → Actions → Runners → **Create new Runner** — it shows an
instance-wide registration token.

**Or, with shell access to the server:**

```bash
docker exec gitea gitea actions generate-runner-token
```

The token is only consumed on the **first** start (while `data/.runner` does not
exist). After registration it is no longer needed.

---

## `config.yaml` — the important bits

`config.yaml` is **generated** — `setup.sh` renders it from
`config.yaml.template` and the per-machine `CI_*` values in `runner.env`, then
the quadlet mounts it read-only. Edit the **template** (portable, committed) or
**runner.env** (per-machine, gitignored) — never the generated file.

```yaml
runner:
  capacity: 1              # from CI_RUNNER_CAPACITY (rendered)
  labels:
    - "ubuntu-latest:docker://ghcr.io/owner/act-ubuntu:26.04"   # from CI_JOB_IMAGE (rendered)
container:
  options: "--memory=2g --cpus=1.5"   # from CI_JOB_MEMORY / CI_JOB_CPUS (rendered)
  docker_host: "-"
```

- **`labels`** — the label left of the first colon (`ubuntu-latest`) **must match
  the workflow's `runs-on:`**. The image right of `docker://` is `CI_JOB_IMAGE`,
  and it must bring node (see [The job image](#the-job-image-ci_job_image)).
- **`docker_host: "-"`** — auto-detect the container host but do **not** bind-mount
  the socket into job containers. Without it, rootless Podman tries to create the
  socket mountpoint on the host and every job fails with *permission denied*.

### Per-machine resource limits

The machine-specific knobs live in **`runner.env`** (gitignored), so the same repo
can drive a weak laptop and a beefy desktop with different caps. Set them, then
`./scripts/setup.sh` to re-render and restart:

| `runner.env` variable | Maps to | Meaning | Empty ⇒ |
|---|---|---|---|
| `CI_RUNNER_CAPACITY` | `runner.capacity` | how many jobs run **at once** | defaults to `1` |
| `CI_JOB_MEMORY` | `--memory` on each job container | max RAM per job (e.g. `2g`, `512m`) | no memory cap |
| `CI_JOB_CPUS` | `--cpus` on each job container | max CPUs per job (`1.5` = 150 %) | no CPU cap |

Suggested profiles:

```ini
# small / old laptop
CI_JOB_MEMORY=2g   CI_JOB_CPUS=1.5   CI_RUNNER_CAPACITY=1
# desktop (8+ cores, 16GB+ RAM)
CI_JOB_MEMORY=2g   CI_JOB_CPUS=2     CI_RUNNER_CAPACITY=2-4
```

The desktop profile was recalibrated from a live measurement (`podman stats`
during real CI runs, not a guess): a native-firmware build job (PlatformIO,
the heaviest workload measured) peaked around 1.3GB RAM and under 2 CPUs, so
`2g`/`2` leaves comfortable headroom without reserving 4g/4 CPUs a job never
actually uses. Since the cap is a ceiling (see below), it's cheap to start
generous and size `CI_RUNNER_CAPACITY` to the host's core count once you've
watched a real run or two.

> **Ceilings, not reservations — and they stack with capacity.** Each cap applies
> **per job container**: a job may use *up to* that much, nothing is pre-allocated
> (unlike a VM), and an idle job leaves the RAM/CPU free for the host. The real peak
> the host must absorb is therefore `CI_RUNNER_CAPACITY × per-job cap` when every slot
> is busy — e.g. capacity `2` × `--memory=4g` = an **8g** ceiling. Keep that product
> comfortably under the machine's RAM/cores. Note the asymmetry: exceeding `--memory`
> **OOM-kills** the job (hard limit), while "exceeding" `--cpus` just **throttles** it
> (soft limit) — so a too-low CPU cap slows builds, a too-low memory cap fails them.

> **Why not limit the runner container instead?** Job containers are started via
> the host Podman socket, so they are **siblings** of the runner container,
> not children. A `MemoryMax=`/`CPUQuota=` on the quadlet would only throttle the
> lightweight orchestrator, not the jobs. The per-job `--memory`/`--cpus` above is
> what actually caps a build.

> **Rootless caveat (cgroup v2 delegation).** For `--cpus`/`--memory` to take
> effect rootless, the controllers must be delegated to your user slice. Memory is
> usually delegated by default; the **CPU** controller often is not. Check with
> `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers` — if
> `cpu` is missing, add a drop-in and reboot:
>
> ```ini
> # /etc/systemd/system/user@.service.d/delegate.conf   (needs root)
> [Service]
> Delegate=cpu cpuset io memory pids
> ```
>
> Without delegation the flags are silently ignored, so limits won't apply — but
> jobs still run. As a safety net, `setup.sh` prints a warning when `CI_JOB_CPUS` is
> set but the `cpu` controller isn't delegated, so this doesn't fail silently.

### The job image (`CI_JOB_IMAGE`)

`CI_JOB_IMAGE` in `runner.env` names the image `ubuntu-latest` runs, and
`setup.sh` refuses to run without it. The image is the one
`job-image.Containerfile` describes: Ubuntu 26.04, as GitHub's own
`ubuntu-latest` is, with node, git, curl, jq, `lsb_release`, Ubuntu's python3
(3.14) and `python3.15` from the [deadsnakes PPA](https://launchpad.net/~deadsnakes/+archive/ubuntu/ppa),
both with `venv`, sudo, unzip, xz and zstd (about 0.4 GB). That covers
`actions/checkout`, `actions/cache` and a workflow that installs the rest itself
with `apt-get`; a native build that expects gcc preinstalled does not get it.
For Python, use the image's `python3` or `python3.15`, with pip inside a venv
(the system Python refuses `pip install`): `setup-python`'s builds for 26.04 need
a CPU with AVX2 (x86-64-v3),
and on a runner without it they stop at their first start (see
[Troubleshooting](#troubleshooting)). A workflow that needs much
more can build its own image `FROM` this one, by digest: the runners then hold
the layers they share once.

`.github/workflows/job-image.yml` builds it on the GitHub mirror, whose job
token can push to ghcr.io and whose runners do the work. A branch only builds
it; `main` also pushes it as `ghcr.io/<owner>/act-ubuntu:26.04`, and as
`:26.04-<run number>` for going back to. It runs when the recipe changes, and
on the 2nd of every month for Ubuntu's package updates; Renovate updates the
recipe's base images on the 1st. Before it pushes, the build runs node, git,
`lsb_release`, zstd and a venv of each Python in the new image.

The runner pulls job images without logging in, so the package has to be
public: check its visibility on the package's page after the first push, or
pull the tag with `podman pull` on a machine that is not logged in to ghcr.io.

Set it on every machine, once `main` has pushed the image:

```bash
# runner.env
CI_JOB_IMAGE=ghcr.io/owner/act-ubuntu:26.04
```

then `./scripts/setup.sh` (it restarts the runner, so wait for running jobs to
finish). When the value changes, `setup.sh` also removes the image
`ubuntu-latest` ran before.

With `force_pull`, every job re-pulls `:26.04`, so a new push reaches the next
job by itself. To go back, point `CI_JOB_IMAGE` at an older
`:26.04-<run number>`.

An image carrying the label `gitea-act-runner.job-image=true` is kept to its
newest copy: `scripts/cleanup.sh` removes the older untagged images of the same
repository. A tagged one stays, so an older `:26.04-<run number>` gone back to
is kept until you remove it with `podman rmi`. The job image carries the label,
and an image a workflow builds `FROM` it inherits it: such an image is pulled by
digest, so a run never leaves it tagged, and without the label its old copies
would pile up.

---

## Operating it

```bash
./scripts/status.sh          # service + container status
./scripts/logs.sh            # follow logs (optional arg: tail line count)
systemctl --user restart gitea-runner.service
git pull && ./scripts/setup.sh   # apply a runner-version bump (Renovate PR) + restart, drop the old image
./scripts/cleanup.sh --dry-run   # list what interrupted jobs left behind (runner stopped)
./scripts/uninstall.sh       # stop + remove, network included (keeps data/.runner)
./scripts/uninstall.sh --purge   # also delete the registration and the cache volume
```

The **job** image is re-pulled before every job (`force_pull: true` in the
template), so it follows its tag (`:26.04`) by itself. To refresh it by hand,
pull the image the rendered `config.yaml` gives `ubuntu-latest`:

```bash
podman pull "$(sed -n 's#.*"ubuntu-latest:docker://\(.*\)"#\1#p' config.yaml)"
```

---

## Reboot / machine-off behavior

`setup.sh` enables user **lingering** and installs the quadlet with
`WantedBy=default.target`, so the runner starts automatically at boot. Turning
the machine off is safe: pushed jobs queue on the server and run by themselves
once the machine is back and the runner reconnects. Nothing hangs server-side.
Before it starts, the service waits up to a minute for the instance's hostname
to resolve (`scripts/wait-for-gitea.sh`), since at boot a user service can
start before the network is up; the runner would retry by itself, but with a
warning in the log at every boot.

A job running when the machine shuts down can leave its container behind, and
with it the job's two volumes, often several GB. The runner never removes such
a container, and while one holds the volumes, its idle cleanup
(`runner.idle_cleanup_interval`) logs a warning on every pass instead of
removing them. `scripts/cleanup.sh` does, and the service runs it before every
start: it removes the `GITEA-ACTIONS-TASK-*` containers that are not running,
the job volumes no container holds, and the older untagged copies of every
image labelled `gitea-act-runner.job-image=true`, which `force_pull` leaves
after a tag moves (see [The job image](#the-job-image-ci_job_image)). A suspend
stops nothing: after resume the same runner still holds the job and tears it
down when it ends.

While less than `health_check.min_free_disk_space_mb` is free, the runner takes
no new jobs; they wait on the server or go to another runner.

---

## Workflow-side requirement (in your app repo, not here)

The runner is useless unless the workflow can actually match it:

1. The job's `runs-on:` must equal the runner **label** (`ubuntu-latest`).
2. Any guard that restricts jobs to github.com (e.g.
   `if: ${{ github.server_url == 'https://github.com' }}`) must be removed or
   inverted, otherwise the jobs **skip** on Gitea.

Note that Gitea also scans `.github/workflows/`, so the same workflow file is
picked up on both platforms.

### `actions/cache` on a self-hosted runner

The runner's built-in cache server serves the **v2** cache API (`cache.v2`, on
by default) next to the legacy v1 one, so the stock `actions/cache@v4+` and
`actions/upload-artifact@v4` work as they do on github.com. Entries live on the
`gitea-runner-cache` volume; the runner drops those left unused and caps each
repository's share (`cache.retention`, `cache.repo_size_limit`) and the whole
cache (`cache.size_limit`), and it sheds entries to keep the free-space floor of
`health_check`. Each machine keeps its own cache, so a job only finds what an
earlier job on the same runner saved.

Jobs reach that server because they run on the runner's own network
(`container.network: gitea-runner`, created by `gitea-runner.network`). Jobs
running at the same time share it, so they can reach each other, and two of
them with a `services:` container of the same name both answer to that name.

The older `gitea/act_runner` (0.x) speaks **v1 only**: there the save step of
`actions/cache@v4.2+` 404s in the "cleanup" phase and fails the job. On such a
runner, gate the cache step to github.com
(`if: ${{ github.server_url == 'https://github.com' }}`) or pin
`actions/cache@v3`.

---

## Compatibility (this repo's own CI)

`.github/workflows/ci.yml` runs `scripts/check.sh` (shellcheck, yamllint and a
secret scan, with the linters pinned in `requirements.txt` and installed into a
gitignored `.venv/`), so running that script locally gives the CI result. It is
written to run on **both**
GitHub Actions and Gitea Actions: `runs-on: ubuntu-latest`, no github-only guard,
and no `actions/cache`, so it also runs on older runners (see the section
above). This mirrors how an app repo can be hosted on Gitea and push-mirrored
to GitHub while CI runs on either side.

---

## Files

| File | Committed? | Notes |
|------|-----------|-------|
| `config.yaml.template` | ✅ | Portable runner config with `__CI_*__` placeholders. |
| `config.yaml` | ❌ generated | Rendered per-machine by `setup.sh`; gitignored. |
| `gitea-runner.container` | ✅ | Quadlet template (path is a placeholder). |
| `gitea-runner.network` | ✅ | Quadlet for the network the runner and its jobs share. |
| `runner.env.example` | ✅ | Template for `runner.env`. |
| `job-image.Containerfile` | ✅ | The small `ubuntu-latest` job image; `.github/workflows/job-image.yml` builds and pushes it. |
| `scripts/*.sh` | ✅ | setup / uninstall / cleanup / status / logs / wait-for-gitea (`--help` on the first three); `check.sh` is the lint gate CI runs, `ensure-venv.sh` its toolchain. |
| `.github/workflows/ci.yml`, `.yamllint` | ✅ | Lint CI + its config. |
| `.github/workflows/job-image.yml` | ✅ | Builds the job image on the GitHub mirror and pushes it from `main` to ghcr.io. |
| `requirements.txt` | ✅ | Pinned linters (shellcheck-py, yamllint) for `scripts/check.sh`; Renovate bumps them. |
| `renovate.json` | ✅ | Renovate config. No custom manager needed: Renovate's built-in `quadlet` manager reads the pinned `gitea/runner` image straight from `gitea-runner.container`, and its `dockerfile` manager the job image's bases from `job-image.Containerfile`. |
| `LICENSE`, `SECURITY.md` | ✅ | MIT license; who can run code on the runner, and secret handling. |
| `AGENTS.md`, `CLAUDE.md` | ✅ | Notes for coding agents; `CLAUDE.md` only imports `AGENTS.md`. |
| `gitea-act-runner.code-workspace` | ✅ | Portable VS Code workspace — open it after cloning. |
| `runner.env` | ❌ gitignored | **Registration token — secret.** Also holds the per-machine `CI_*` resource limits and job image. |
| `data/.runner` | ❌ gitignored | **Runner identity — secret.** |

---

## Troubleshooting

- **Jobs fail instantly, log shows `mkdir /var/run/docker.sock: permission
  denied`** → `docker_host: "-"` is missing from `config.yaml`.
- **`instance address is empty` at registration** → the container entrypoint
  registers from env vars and ignores CLI `register` args; make sure
  `GITEA_INSTANCE_URL` / `GITEA_RUNNER_REGISTRATION_TOKEN` are set in
  `runner.env`.
- **Jobs `skipped`** → the workflow guard still restricts to github.com, or
  `runs-on:` does not match the runner label.
- **Job fails at "cleanup" after building fine** → a runner whose cache server
  speaks v1 only (the old `gitea/act_runner` 0.x); see the `actions/cache`
  section above.
- **Every job fails at the first `uses:` step, log shows `failed to copy
  content to container: ... path escapes from parent`** → a Podman/Buildah
  regression, not a config issue: recent Buildah versions refuse to copy an
  archive into a container path that crosses an absolute symlink, and the job
  image's `/var/run → /run` is exactly that. Affects every job on the runner,
  not just one repo. Check `podman -v` / `buildah -v` against the [upstream
  issue](https://github.com/podman-container-tools/podman/issues/29805) for
  the current fix status; the known-working combination is
  `podman 5.8.4` / `buildah 1.43.2`.
- **`actions/cache` never saves: "Unable to reserve cache … another job may be
  creating this cache", and every restore "Cache not found"** → the job cannot
  reach the runner's cache server. Check that `container.network` in `config.yaml` names the
  network the runner container is on (`podman inspect gitea-runner`).
- **Every job and the runner lose name resolution after a job whose name has a
  space or a comma (matrix jobs such as `test (3.8)`): "Could not resolve
  host", and the runner logs `lookup … on 10.89.0.1:53: … connection refused`
  and fetches no more jobs** → Netavark older than 1.15 (Podman 4.x distros;
  `netavark --version`, under `/usr/libexec/podman/` or `/usr/lib/podman/`).
  The runner gives each job container its job name as a network alias, Netavark
  writes it unchecked into aardvark-dns's space-separated config, and
  aardvark-dns exits on its next reload
  ([netavark#1019](https://github.com/containers/netavark/issues/1019)).
  Netavark 1.15+ skips such an alias. On an older one, give the job a name
  without spaces or commas; a name with an expression gets no matrix suffix,
  e.g. `name: test-${{ matrix.python-version }}`. Restart the runner to bring
  aardvark-dns back.
- **`setup-python` fails right after the download: `./python: CPU ISA level is
  lower than required`** → the runner's CPU has no AVX2. The Python builds
  `setup-python` downloads for Ubuntu 26.04 are compiled for x86-64-v3 (`readelf
  -n` shows `x86 ISA needed: … x86-64-v3`);
  `/lib64/ld-linux-x86-64.so.2 --help` lists the levels the CPU supports. Only jobs that land on such a runner fail, so the same workflow
  can pass on the next run. Drop `setup-python` and use the job image's
  `python3` with a venv (see [The job image](#the-job-image-ci_job_image)).
- **Runner not online** → `./scripts/logs.sh`; check the URL is reachable
  (`curl -sf $GITEA_INSTANCE_URL/api/v1/version`) and the token was valid.
- **Commands not found from inside a sandboxed shell** (e.g. a Flatpak'd editor
  terminal) → run `podman` / `systemctl` on the host, prefixing with the
  sandbox's host escape (e.g. `flatpak-spawn --host`).

---

## License

[MIT](LICENSE).
