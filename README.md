# gitea-act-runner

Run a **Gitea / Forgejo Actions runner** as a rootless **Podman** container,
managed by a **systemd** user *quadlet* so it survives reboots and starts on its
own. Clone the repo, drop in a registration token, run one script.

The runner uses a **pull model**: it long-polls the server over gRPC (outbound
only), so it works behind NAT/firewall with no inbound port. If the machine is
off when a job is pushed, the job simply queues on the server and runs once the
machine is back and the runner reconnects.

> **Scope / compatibility.** Linux only, with **rootless Podman ≥ 4.4** (quadlet
> support) and a **systemd user session**. Targets **Gitea** (1.20+) and
> **Forgejo** Actions. Docker and non-systemd setups are out of scope. Developed
> on Podman 5.8 / Fedora-based (SELinux).

---

## How it works

| Piece | Role |
|-------|------|
| `gitea/act_runner` container | Registers with the server, polls for jobs, launches a job container per job. |
| `config.yaml` | Runner config. The key line is the **label → image** mapping. |
| `runner.env` | Registration inputs (instance URL, token, name). **Secret — gitignored.** |
| `data/.runner` | Registration state written after first start. **Secret — gitignored.** |
| `gitea-runner.container` | Quadlet unit template; `scripts/setup.sh` installs it. |
| systemd user service + lingering | Auto-start on boot, restart on failure, no login needed. |

Jobs run in a **full** environment image (`catthehacker/ubuntu:act-latest`),
which has gcc, python, etc. — required for native compilation, `setup-python`,
and similar. A slim `node:*` image is **not** enough.

---

## Prerequisites

- Rootless **Podman ≥ 4.4** (developed on 5.8).
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
${EDITOR:-nano} runner.env      # paste GITEA_RUNNER_REGISTRATION_TOKEN, set the name + URL

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

```yaml
runner:
  labels:
    - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest"
container:
  docker_host: "-"
```

- **`labels`** — the label left of the first colon (`ubuntu-latest`) **must match
  the workflow's `runs-on:`**. The image right of `docker://` **must be a full
  environment**, not a slim node image.
- **`docker_host: "-"`** — auto-detect the container host but do **not** bind-mount
  the socket into job containers. Without it, rootless Podman tries to create the
  socket mountpoint on the host and every job fails with *permission denied*.
- `capacity: 1` — one job at a time (fine for a single machine).

---

## Operating it

```bash
./scripts/status.sh          # service + container status
./scripts/logs.sh            # follow logs (optional arg: tail line count)
systemctl --user restart gitea-runner.service
podman pull docker.io/gitea/act_runner:latest && \
  systemctl --user restart gitea-runner.service   # update the runner image
./scripts/uninstall.sh       # stop + remove (keeps data/.runner)
./scripts/uninstall.sh --purge   # also delete the registration
```

To also update the **job** image:

```bash
podman pull ghcr.io/catthehacker/ubuntu:act-latest
```

---

## Reboot / machine-off behavior

`setup.sh` enables user **lingering** and installs the quadlet with
`WantedBy=default.target`, so the runner starts automatically at boot. Turning
the machine off is safe: pushed jobs queue on the server and run by themselves
once the machine is back and the runner reconnects. Nothing hangs server-side.

---

## Workflow-side requirement (in your app repo, not here)

The runner is useless unless the workflow can actually match it:

1. The job's `runs-on:` must equal the runner **label** (`ubuntu-latest`).
2. Any guard that restricts jobs to github.com (e.g.
   `if: ${{ github.server_url == 'https://github.com' }}`) must be removed or
   inverted, otherwise the jobs **skip** on Gitea.

Note that Gitea also scans `.github/workflows/`, so the same workflow file is
picked up on both platforms.

### Caveat: `actions/cache` on a self-hosted runner

`act_runner`'s built-in cache server speaks the **legacy v1** cache API, but
`actions/cache@v4.2+` (and `@v6`) use the **v2** protocol. The save step then
404s in the "cleanup" phase and fails the job. Gate the cache step to github.com
(`if: ${{ github.server_url == 'https://github.com' }}`) so it is skipped on
Gitea, or pin `actions/cache@v3` for Gitea-only.

---

## Compatibility (this repo's own CI)

`.github/workflows/lint.yml` (shellcheck + yamllint) is written to run on **both**
GitHub Actions and Gitea Actions: `runs-on: ubuntu-latest`, no github-only guard,
and no `actions/cache` (see the caveat above). This mirrors how an app repo can be
hosted on Gitea and push-mirrored to GitHub while CI runs on either side.

---

## Files

| File | Committed? | Notes |
|------|-----------|-------|
| `config.yaml` | ✅ | Runner config (no secrets). |
| `gitea-runner.container` | ✅ | Quadlet template (path is a placeholder). |
| `runner.env.example` | ✅ | Template for `runner.env`. |
| `scripts/*.sh` | ✅ | setup / uninstall / status / logs (`--help` on the first two). |
| `.github/workflows/lint.yml`, `.yamllint` | ✅ | Lint CI + its config. |
| `LICENSE`, `SECURITY.md` | ✅ | MIT license, secret-handling policy. |
| `gitea-act-runner.code-workspace` | ✅ | Portable VS Code workspace — open it after cloning. |
| `runner.env` | ❌ gitignored | **Registration token — secret.** |
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
- **Job fails at "cleanup" after building fine** → the `actions/cache` v1/v2
  mismatch above.
- **Runner not online** → `./scripts/logs.sh`; check the URL is reachable
  (`curl -sf $GITEA_INSTANCE_URL/api/v1/version`) and the token was valid.
- **Commands not found from inside a sandboxed shell** (e.g. a Flatpak'd editor
  terminal) → run `podman` / `systemctl` on the host, prefixing with the
  sandbox's host escape (e.g. `flatpak-spawn --host`).

---

## License

[MIT](LICENSE).
