# Gitea Actions runner (podman quadlet)

A self-contained, cloneable setup for running a **Gitea Actions runner** as a
rootless **podman** container, managed by **systemd** (quadlet) so it survives
reboots and starts on its own. Clone the repo, drop in a registration token, run
one script.

The runner uses a **pull model**: it long-polls Gitea over gRPC (outbound only),
so it works behind NAT/firewall with no inbound port. If the machine is off when
a job is pushed, the job simply queues in Gitea and runs once the machine is
back and the runner reconnects.

---

## How it works

| Piece | Role |
|-------|------|
| `gitea/act_runner` container | Registers with Gitea, polls for jobs, launches a job container per job. |
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

- Rootless **podman** (v4+; developed on 5.8).
- **systemd** user session available (`systemctl --user`).
- Ability to enable **lingering** (`loginctl enable-linger <user>`; may need sudo).
- Network access from this machine to the Gitea instance (normal HTTPS client).

---

## Quick start

```bash
git clone <this-repo> ci-runner
cd ci-runner

# 1. Provide the registration token and instance settings.
cp runner.env.example runner.env
${EDITOR:-nano} runner.env      # paste GITEA_RUNNER_REGISTRATION_TOKEN, set the name

# 2. Install + start (idempotent — safe to re-run).
./scripts/setup.sh
```

Then check **Gitea → Site Administration → Actions → Runners**: the runner should
appear **online (green)** with the `ubuntu-latest` label.

---

## Getting a registration token

**From the Gitea web UI (as admin):**
Site Administration → Actions → Runners → **Create new Runner** — it shows an
instance-wide registration token.

**Or, if you have shell access to the Gitea host:**

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
  the socket into job containers. Without it, rootless podman tries to create the
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
the machine off is safe: pushed jobs queue in Gitea and run by themselves once
the machine is back and the runner reconnects. Nothing hangs on the Gitea side.

---

## Workflow-side requirement (in the app repo, not here)

The runner is useless unless the workflow can actually match it:

1. The job's `runs-on:` must equal the runner **label** (`ubuntu-latest`).
2. Any guard that restricts jobs to github.com (e.g.
   `if: ${{ github.server_url == 'https://github.com' }}`) must be removed or
   inverted, otherwise the jobs **skip** on Gitea.

Note that Gitea also scans `.github/workflows/`, so the same workflow file is
picked up on both platforms.

---

## Files

| File | Committed? | Notes |
|------|-----------|-------|
| `config.yaml` | ✅ | Runner config (no secrets). |
| `gitea-runner.container` | ✅ | Quadlet template (path is a placeholder). |
| `runner.env.example` | ✅ | Template for `runner.env`. |
| `scripts/*.sh` | ✅ | setup / uninstall / status / logs. |
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
- **Jobs `skipped` in Gitea** → the workflow guard still restricts to github.com,
  or `runs-on:` does not match the runner label.
- **Runner not online** → `./scripts/logs.sh`; check the URL is reachable
  (`curl -sf $GITEA_INSTANCE_URL/api/v1/version`) and the token was valid.
- **Running these scripts from inside a Flatpak sandbox** (e.g. VS Code Flatpak)
  → prefix host commands with `flatpak-spawn --host`.
