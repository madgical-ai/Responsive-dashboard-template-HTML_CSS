# CI/CD Pipeline Walkthrough

This workflow takes a containerized app from commit to running container on EC2. It runs on every push to `main` and every PR targeting `main`. A concurrency group (`workflow + ref`) cancels superseded runs, and default permissions are read-only (`contents: read`) with elevated scopes granted per job.

## Stage map

```
validate ─┐
test ─────┼─> build ─> publish ─> deploy-staging ─> staging-health ─> staging-smoke
security ─┘                                                              │
                                                                         v
                        rollback <── (on failure) ── deploy-production ─> production-health ─> production-smoke ─> post-deploy
```

On pull requests only the first three jobs run; everything from `build` onward is gated on `push` or `workflow_dispatch`.

## Job-by-job

### 1. `validate`
Static checks before anything is built. Runs hadolint against `Dockerfile` with `failure-threshold: error`, installs PyYAML, and parses the workflow file to catch YAML syntax errors. Fast feedback for Dockerfile and workflow edits.

### 2. `test`
Builds the image as `<owner>/<repo>:test`, starts it detached on `8080:8080`, then polls `http://localhost:8080/` up to 15 times with a 2s delay. If the container never answers, the job fails. Container logs are captured to `test-output.log` and uploaded even on failure (`if: always()`), alongside any `reports/**` and `dist/**` artifacts.

### 3. `security`
Three scanners in parallel-ish sequence:
- **Trivy** filesystem scan — fails the job on any CRITICAL or HIGH finding.
- **Gitleaks** — scans git history (`fetch-depth: 0`) for committed secrets.
- **Semgrep** — `config: auto` static analysis; requires `SEMGREP_APP_TOKEN`.

### 4. `build`
Runs only after validate, test and security all pass, and only on push/dispatch. Builds the image with Buildx using GitHub Actions cache (`type=gha`), loads it locally, then runs a Trivy **image** scan with the same CRITICAL/HIGH gate. Nothing is pushed yet — this is the last chance to catch a bad image.

### 5. `publish`
Logs in to GHCR with `GITHUB_TOKEN`, then **preserves the current `latest` as `:previous`** (pull → tag → push) so rollback has a target. Finally builds and pushes both `:latest` and `:${{ env.IMAGE_TAG }}` (currently `latest`, so effectively the same tag).

### 6. `deploy-staging`
Assumes an AWS role via OIDC and sends a shell script to the EC2 instance through SSM `AWS-RunShellScript`. The remote script:
1. Installs Docker if missing (dnf/yum/apt-get) and starts the daemon.
2. Logs in to GHCR and pulls the image.
3. Starts a **canary** container named `<app>-new`.
4. Health-checks it from inside the container (`curl` or `wget` on the container port).
5. Only if healthy, stops/removes the old container and starts the real one with `--restart unless-stopped -p 80:8080`.
6. Prunes dangling images.

The workflow polls `get-command-invocation` for up to 5 minutes and fails on `Failed`/`Cancelled`/`TimedOut`, printing stderr.

### 7. `staging-health` and `staging-smoke`
External verification against `APP_URL`. Health check retries 10 times with 6s delay and `--retry-connrefused`; the smoke test asserts the response contains `<html`.

### 8. `deploy-production`
Identical mechanics to staging, but with the comment `Deploy production container <sha>`. Note it targets the same instance, container name and URL as staging.

### 9. `production-health` and `production-smoke`
Same external checks as staging, run against the production URL.

### 10. `rollback`
Triggered by `if: failure()` when `deploy-production`, `production-health` or `production-smoke` fail. Pulls `:<repo>:previous` and restarts the container from it via SSM. This is the safety net for a bad release.

### 11. `post-deploy`
Runs only on full success and simply echoes the deployed repo, SHA and URL — a human-readable marker in the run log.

## Prerequisites

**Application / image**
- A `Dockerfile` at the repository root (no build args are declared or passed).
- Base image: `nginxinc/nginx-unprivileged:alpine` — runs as a non-root user.
- The container must listen on **port 8080** (`EXPOSE 8080`) and start with `CMD ["nginx", "-g", "daemon off;"]`.
- The app must return HTTP 200 on `/` and the body must contain `<html` (required by the smoke tests).
- The image must contain `curl` **or** `wget` for the in-container health check (busybox `wget` in Alpine satisfies this).

**Runner requirements (`ubuntu-latest`)**
- Docker Engine + Buildx (`docker/setup-buildx-action`).
- `python3` and `pip` (installs `pyyaml`).
- `jq` and `curl` (used by the deploy/rollback scripts).
- Outbound network access to `ghcr.io` and to the deployed host.

**Target host (EC2)**
- SSM Agent installed and the instance registered in the configured region.
- A package manager (`dnf`, `yum` or `apt-get`) so Docker can be installed if absent.
- Ability to reach `ghcr.io` to pull the image.
- Host port **80** free for the container mapping (`HOST_PORT=80` → `CONTAINER_PORT=8080`).

**AWS**
- An IAM role assumable via GitHub OIDC with `ssm:SendCommand` and `ssm:GetCommandInvocation` permissions.
- The EC2 instance ID of the deployment target.

**Required secrets**
| Secret | Purpose |
| --- | --- |
| `AWS_REGION` | Region for SSM and credential config |
| `AWS_DEPLOY_ROLE_ARN` | OIDC role assumed by deploy/rollback jobs |
| `EC2_INSTANCE_ID` | Target instance for SSM commands |
| `SEMGREP_APP_TOKEN` | Semgrep scan authentication |
| `GITHUB_TOKEN` | Auto-provided; GHCR login and Gitleaks |
| `GHCR_USER` / `GHCR_TOKEN` | Optional; fall back to `github.actor` / `GITHUB_TOKEN` |
| `DEPLOYMENT_NAME` | Optional container name; defaults to `app` |

**Environment variables (workflow-level)**
- `REGISTRY=ghcr.io`, `IMAGE_TAG=latest`
- `HOST_PORT=80`, `CONTAINER_PORT=8080`
- `APP_URL=http://44.197.226.160:80` — used by all health and smoke checks

**Permissions**
- `contents: read` (global), `packages: write` (build/publish/deploy), `id-token: write` (deploy/rollback), `pull-requests: write` (security job).

## Things to watch

- **Staging and production are the same environment.** Both deploy jobs use the same instance, container name and `APP_URL`, so a staging deploy overwrites production and vice versa.
- **Mutable tags.** `IMAGE_TAG` is `latest`, so the only versioned artifact is the `:previous` tag written by `publish`. A failed `publish` leaves rollback without a target.
- **`cancel-in-progress: true`** can kill a run in the middle of a deploy.
- **No environment protection rules** — production deploys automatically once staging smoke passes.
- **`env.ACT` guards** on scanner and curl steps let the workflow run under `act` locally, but those checks are silently skipped there.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`

Unresolved / failed to provision (add manually in GitHub before merging):
- [ ] `SEMGREP_APP_TOKEN`
