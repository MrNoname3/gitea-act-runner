# Security

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
