# CI Pipeline Walkthrough

A developer-facing guide to what this workflow does, why each stage exists, and what the project needs in place before CI can run.

## Overview

The workflow is defined in `.github/workflows/ci.yml` and has seven jobs. Three of them (`validate`, `test`, `security`) are quality gates that run on every pull request. The remaining four (`build`, `publish`, `deploy`, `health-check`) form a release chain that runs only when code lands on `main` or when someone triggers the workflow manually via `workflow_dispatch`.

## Triggers and concurrency

- **`pull_request` to `main`** — runs the three quality gates only.
- **`push` to `main`** — runs the quality gates, then builds, publishes, deploys, and health-checks.
- **`workflow_dispatch`** — same as a push, but started by hand.
- **Concurrency** — the group is `workflow + ref` with `cancel-in-progress: true`, so a newer run on the same branch cancels the older one. This saves runner minutes but means a freshly queued push can abort a deploy that is mid-flight.
- **Permissions** — the workflow defaults to read-only `contents`; individual jobs widen this only where needed (`packages: write` for publish, `id-token: write` for deploy's OIDC exchange).

## Job-by-job

### 1. `validate` — Lint and type check
Runs on `ubuntu-latest` with a 30-minute timeout. After checking out the repo it inspects the project and runs only the tooling that applies:
- If `package.json` exists: `npm ci` (when a lockfile is present) and `npm run lint`.
- If `pyproject.toml` or `requirements.txt` exists: installs `ruff` and runs `ruff check .`.
- If `tsconfig.json` exists: `npx tsc --noEmit`.
- If `pyproject.toml` exists: installs `mypy` and runs `mypy .`.

**Why:** catch style and type errors before they reach review, and keep the check language-agnostic so the same workflow fits either a Node or a Python service. The `env.ACT != 'true'` guards let developers run the file locally through `act` without invoking the real linters.

### 2. `test` — Unit, integration, coverage
Also `ubuntu-latest`. Runs `npm test` and/or `pytest -q` depending on what is detected, then integration tests and coverage collection (both currently placeholders that just echo). It uploads two artifacts:
- `test-results` from `coverage/` and `test-results/`, always uploaded even if the job fails.
- `test-artifacts` from `reports/` and `dist/`, uploaded with a warning if nothing matches.

**Why:** produce machine-readable test output for reviewers and keep results available after a failed run.

### 3. `security` — Secret, dependency, and code scanning
Checks out with `fetch-depth: 0` so the full history is available for diff-aware scanning. Three steps:
- **Gitleaks** — scans for committed secrets; uses `secrets.GITHUB_TOKEN`.
- **Trivy filesystem scan** — reports CRITICAL/HIGH issues but is deliberately non-blocking (`exit-code: 0`).
- **Static code scan** — currently a placeholder echo.

**Why:** block leaked credentials and keep a visible record of dependency risk without hard-failing on findings that may not have a fix yet.

### 4. `build` — Build and scan the image
Gated on `needs: [validate, test, security]` and on the event being a push or manual dispatch. It:
1. Sets up Docker Buildx.
2. Lowercases the repository name into `ghcr.io/<owner>/<repo>` and exports it as `IMAGE_NAME`.
3. Builds the image tagged with the commit SHA.
4. Scans that image with Trivy (`exit-code: 1`, `ignore-unfixed: true`, `severity: CRITICAL,HIGH`) — this step **does** fail the pipeline.
5. Writes the image reference to `image-metadata.txt` and uploads it as the `image-metadata` artifact.

**Why:** verify the image is buildable and free of fixable high-severity CVEs before it is ever pushed to a registry.

### 5. `publish` — Push to GHCR
Gated on `needs: build` and a push/dispatch event. Requires `packages: write`. It logs in to `ghcr.io` with `github.repository_owner` and the built-in `GITHUB_TOKEN`, rebuilds the image, and pushes two tags: `:<commit-sha>` and `:latest`.

**Why:** the deploy job pulls from the registry rather than shipping a tarball, so the exact SHA-tagged artifact that was scanned is the one that gets deployed.

### 6. `deploy` — Deploy to EC2 via SSM
Gated on `needs: publish`. Requires `id-token: write` so it can assume an AWS role through GitHub's OIDC provider — no long-lived AWS keys are stored in the repo. The job:
1. Assumes `AWS_DEPLOY_ROLE_ARN` in `us-east-1`.
2. Builds a JSON command document with `jq` and sends it to the target instance with `aws ssm send-command` using the `AWS-RunShellScript` document.
3. Polls `get-command-invocation` every 10 seconds, up to 30 attempts, and exits non-zero on `Failed`, `Cancelled`, or `TimedOut`.

The remote script performs a blue/green-style swap:
- Installs Docker if missing (dnf, yum, or apt-get) and starts the daemon.
- Logs in to the registry with `GHCR_USER` / `GHCR_TOKEN`.
- Pulls the SHA-tagged image.
- Starts it as `<DEPLOYMENT_NAME>-new` and waits for `GET /` on the container port to succeed.
- Stops and removes the old container, then runs the new image as `<DEPLOYMENT_NAME>` with `-p 80:8080 --restart unless-stopped`.
- Verifies `GET /` on the host port and prunes dangling images.

**Why:** keep the old container serving traffic until the new one passes an in-container health check, so a bad release never takes the site down.

### 7. `health-check` — Production verification
Gated on `needs: deploy`. It retries `APP_URL/` twelve times with a five-second gap, then runs a smoke test against the same URL, and uploads a `health-check-artifacts` artifact.

**Why:** confirm the deployment is reachable from the public internet, not just from inside the container.

## How the stages connect

```
validate ─┐
test ─────┼─> build ─> publish ─> deploy ─> health-check
security ─┘
```

The three quality gates run in parallel and all must succeed before `build` starts. `publish` consumes the image reference produced by `build`. `deploy` consumes the pushed SHA tag. `health-check` is the final confirmation that the live URL responds. On pull requests the chain stops after `security`, which is why a PR can be green without ever exercising the Dockerfile.

## Prerequisites

### Runtime and versions
- **Python 3.12** — the workflow sets `PYTHON_VERSION: '3.12'` and installs `ruff`, `mypy`, and `pytest` via pip. Note the env var is not wired into a `setup-python` step, so the runner's default Python is what actually executes; pin it explicitly if the project needs 3.12 specifically.
- **Node.js and npm** — required only if the repository contains `package.json`. `npm ci` is used, so a `package-lock.json` must be committed for installs to run.
- **`jq`** — used by the deploy job to build the SSM command payload. It is preinstalled on `ubuntu-latest`.

### Docker
- **Base image:** `nginxinc/nginx-unprivileged:alpine`. It runs as a non-root user, so the container cannot bind privileged ports internally.
- **Exposed port:** `8080`. The image is started with `CMD ["nginx", "-g", "daemon off;"]`.
- **Build context:** the repository root (the build command is `docker build .`).
- **Build args:** none are declared or passed. If the Dockerfile gains build args, they must be added to both the `build` and `publish` jobs.

### System packages
- On the GitHub runners: Docker, Buildx, `jq`, and `curl` come from the `ubuntu-latest` image.
- On the EC2 host: Docker is installed by the deploy script itself (via `dnf`, `yum`, or `apt-get`) if it is not already present, and `curl` or `wget` is required for the in-container health checks.

### Ports and networking
- **EC2 host port `80`** (`HOST_PORT`) mapped to **container port `8080`** (`CONTAINER_PORT`).
- The EC2 security group must allow inbound HTTP on port 80 from wherever `APP_URL` is reached.
- The host must be able to reach `ghcr.io` to pull the image.

### Required secrets and environment variables

| Name | Scope | Purpose |
| --- | --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | secret | IAM role assumed via OIDC in the deploy job |
| `EC2_INSTANCE_ID` | secret | Target instance for the SSM command |
| `DEPLOYMENT_NAME` | secret | Container name and name prefix on the host |
| `GHCR_TOKEN` | secret | Registry pull credential used on the EC2 host |
| `GHCR_USER` | secret | Registry username (falls back to `github.actor`) |
| `GITHUB_TOKEN` | auto | Used by Gitleaks and by the publish job's GHCR login |
| `REGISTRY` | env | `ghcr.io` |
| `IMAGE_TAG` | env | The commit SHA used as the image tag |
| `IMAGE_NAME` | env | `ghcr.io/<owner>/<repo>` |
| `AWS_REGION` | env | `us-east-1` |
| `HOST_PORT` / `CONTAINER_PORT` | env | `80` and `8080` |
| `APP_URL` | env | `http://3.89.79.100`, used by the final health check |

### AWS prerequisites
- An IAM OIDC identity provider for `token.actions.githubusercontent.com` and a role whose trust policy allows this repository.
- The role needs `ssm:SendCommand` and `ssm:GetCommandInvocation` permissions for the target instance.
- The EC2 instance must be registered with SSM (the SSM agent running) and have outbound access to the registry and to AWS endpoints.

### Build args
None. There are no `ARG` values passed at build time.

## Known gaps and risks

- **PRs skip the image build.** A broken Dockerfile only fails after merge to `main`, in the `build` job.
- **Filesystem Trivy scan is advisory.** `exit-code: 0` means dependency findings never block a PR; only the image scan in `build` can fail the pipeline.
- **`GHCR_TOKEN` fallback is unsafe.** If `GHCR_TOKEN` is unset, the remote script uses `GITHUB_TOKEN`, which is scoped to the workflow run and will not authenticate a registry pull on EC2.
- **No rollback.** The old container is removed after the new one passes its check, but if the swap or host-port check fails there is no automatic restore, and a leftover `<DEPLOYMENT_NAME>-new` container can remain.
- **Hardcoded production URL.** `APP_URL` points at a fixed IP; it will need updating if the instance is replaced.
- **Placeholder steps.** The integration tests, coverage collection, static code scan, and several artifact uploads currently only echo or match nothing, so a green run does not yet mean those checks executed.
- **Container environment.** The deploy step runs the image with no `-e` flags, so any configuration the app needs must be baked into the image.

## Troubleshooting quick reference

| Symptom | Where to look |
| --- | --- |
| Lint or type errors | `validate` job logs |
| Test failures or missing artifacts | `test` job logs and the `test-results` artifact |
| Secret detected | `security` job, Gitleaks output |
| Image fails to build | `build` job, Docker build step |
| CVE blocks the pipeline | `build` job, Trivy image scan step |
| Push rejected | `publish` job, GHCR login step and `packages: write` permission |
| Deploy hangs or fails | `deploy` job, `ssm-output.json` status and `StandardErrorContent` |
| Site unreachable after deploy | `health-check` job and the EC2 security group |

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
