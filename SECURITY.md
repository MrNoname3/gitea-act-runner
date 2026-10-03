# Security

## Who can run code on this machine

A registered runner executes whatever the workflows it serves tell it to.
Anyone who can make a workflow run on it, by pushing to a repository it serves
or by any other event that repository's workflows react to, runs code on this
machine, inside a job container.

**What a job container gets:** the runner's network, with outbound access, the
LAN included, shared with the runner and with every other job running at that
moment; the per-job `--memory`/`--cpus` caps from `runner.env`; and the
secrets its repository is given. It does **not** get the Podman socket
(`docker_host: "-"`), any host path (`valid_volumes: []` forbids every mount),
or privileged mode (`privileged: false`). With privileged off, the runner also
drops the options from a workflow's own `container.options` that could escape
the container (`--pid`, `--cap-add`, `--security-opt`, `--device` and the
like). Loosening any of these three settings loosens them for every workflow
on every repository the runner serves.

**What the runner container holds:** the host's rootless Podman socket, which
it needs to start job containers. Whoever controls that socket controls every
container of the account running the runner, and through a bind mount that
account's files, so treat it as a login as that user. That is why the socket
stops at the runner and never reaches a job. Its cache server, which jobs do
reach, ties each entry to the repository of the job that saved it, so a job
cannot read or overwrite another repository's cache.

**Narrowing who that is:** the token from *Site Administration* registers an
instance-wide runner, which takes jobs from every repository on the instance.
On an instance with other users, register with a token scoped to an
organization, a user or a single repository instead, so that only that scope's
workflows run here.

## Secrets in this repo

Two files hold secrets and are **git-ignored** — never commit them:

- **`runner.env`** — contains `GITEA_RUNNER_REGISTRATION_TOKEN`, an
  instance-wide token that lets the holder register runners against your Gitea.
- **`data/.runner`** — the runner's identity after registration (a secret UUID
  that authenticates *this* runner to Gitea).

Only `runner.env.example` (a placeholder template) is tracked. Before pushing,
verify nothing sensitive is staged:

```bash
git check-ignore runner.env data/.runner   # both should be listed
git grep -nI -e token -e YOUR_INSTANCE      # sanity sweep
```

## If a secret leaks

- **Registration token** — in Gitea, go to *Site Administration → Actions →
  Runners*, delete the exposed runner(s), and create a new runner to rotate the
  token. Update `runner.env` and re-run `scripts/setup.sh`.
- **`data/.runner`** — delete the runner in the Gitea UI, then
  `./scripts/uninstall.sh --purge` and set it up again to re-register.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.
On GitHub use *Security → Report a vulnerability* (private advisory), or contact
the maintainer directly. You will get an acknowledgement as soon as possible.
