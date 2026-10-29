# CI Pipeline Walkthrough

This pipeline takes a containerized nginx application from pull request to running containers on AWS EC2. It is triggered on pushes and PRs to `main`, plus manual `workflow_dispatch`. Concurrency is scoped per workflow+ref with `cancel-in-progress`, so a newer run supersedes an older one on the same branch.

## Prerequisites

**Application runtime / image**
- Base image: `nginxinc/nginx-unprivileged:alpine` (runs as non-root, listens on **8080**).
- Container command: `nginx -g "daemon off;"`.
- No build args or runtime env vars are declared in the Dockerfile; the app is served statically by nginx.

**Ports**
- Container port: `8080` (must match `CONTAINER_PORT`).
- Host port: `80` (`HOST_PORT`), so the EC2 instance must allow inbound HTTP on 80.

**CI runner requirements**
- `ubuntu-latest` GitHub-hosted runners with Docker, Buildx, `curl`, `jq`, and Python 3 + PyYAML (for the workflow syntax check).
- GitHub Actions cache (`type=gha`) for Buildx layers.

**Deployment host requirements (EC2)**
- SSM Agent installed and the instance registered with AWS Systems Manager.
- Docker installed (the deploy script installs it via `dnf`/`yum`/`apt-get` if missing).
- Outbound access to `ghcr.io` to pull images.
- `curl` or `wget` inside the container for the in-container health probe.

**Secrets / variables**
- `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC (`id-token: write`).
- `EC2_INSTANCE_ID` — target instance for SSM commands.
- `DEPLOYMENT_NAME` — container name prefix used for blue/green swap.
- `GHCR_USER` / `GHCR_TOKEN` — optional; fall back to `github.actor` / `GITHUB_TOKEN`.
- `GITHUB_TOKEN` — used by Gitleaks and GHCR login.

**Workflow env**
- `REGISTRY=ghcr.io`, `IMAGE_TAG=latest`, `AWS_REGION=us-east-1`, `HOST_PORT=80`, `CONTAINER_PORT=8080`.

## Jobs

### 1. Validate
Runs Hadolint against `Dockerfile` with `failure-threshold: error`, then parses `.github/workflows/ci.yml` with Python's YAML loader. This catches Dockerfile anti-patterns and malformed workflow syntax before anything expensive runs.

### 2. Test
Builds the image locally as `ci-test:local`, starts it detached on `8080:8080`, and polls `http://localhost:8080/` up to 15 times (2s apart). If the endpoint never responds, the job fails. Artifacts (`Dockerfile`, `reports/**`, `dist/**`) are uploaded for inspection.

### 3. Security
Three independent scanners run in one job:
- **Trivy (fs)** — fails the build on HIGH/CRITICAL findings, ignoring unfixed CVEs, and writes SARIF.
- **Gitleaks** — scans the repo for committed secrets with redacted output.
- **Semgrep** — runs the `auto` ruleset for code-level issues.

### 4. Build
Only runs on `push` or manual dispatch, and only after validate, test, and security pass. It lowercases the repo name into a GHCR image path, builds with Buildx using GitHub Actions layer cache, tags `latest` and the commit SHA, then re-scans the built image with Trivy (fails on HIGH/CRITICAL).

### 5. Publish
Repeats the image-name computation, logs into `ghcr.io` with `GITHUB_TOKEN`, and pushes both tags using `docker/build-push-action`. Requires `packages: write`.

### 6. Deploy (Staging)
Assumes the AWS role via OIDC, then sends an `AWS-RunShellScript` SSM command to the instance. The remote script:
1. Installs/starts Docker if needed.
2. Logs into GHCR and pulls the image.
3. Starts a temporary `<name>-new` container and probes `/` inside it.
4. Stops and removes the old container, then starts the new one with `--restart unless-stopped -p 80:8080`.
5. Prunes dangling images.

The job polls the SSM command status for up to 5 minutes, then curls the instance's public DNS as a health check and smoke test.

### 7. Deploy (Production)
Identical mechanics to staging, gated on staging success. Note that it targets the same instance and container name, so it replaces the staging deployment.

### 8. Rollback
Runs only if production deployment fails. It re-issues an SSM command that starts the existing container and lists containers. This is a best-effort restart, not a versioned rollback — no previous image tag is retained.

### 9. Post Deploy
On success, prints the deployed image reference, the host→container port mapping, and the health endpoint for the run log.

## Flow

```
validate ─┐
test ─────┼─► build ─► publish ─► deploy-staging ─► deploy-production ─► post-deploy
security ─┘                                              └─(failure)─► rollback
```

PRs stop after the security job; only pushes and manual runs proceed to build and deploy.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
