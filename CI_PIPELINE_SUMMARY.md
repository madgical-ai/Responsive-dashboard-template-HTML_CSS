# CI/CD Pipeline Walkthrough

This pipeline takes a commit from `main` through security scanning, testing, container build, and staged ECS deployment with manual production approval and rollback safety nets.

## Prerequisites

Before CI can run, the project and AWS environment must provide:

- **Runtime**: Node.js 20 (installed via `actions/setup-node`); `npm ci` requires a committed `package-lock.json`.
- **Docker base image**: `nginx:alpine` (from `Dockerfile`).
- **System packages in image**: `curl` (installed in the Dockerfile).
- **Exposed port**: `80` (container listens on 80; workflow maps `HOST_PORT=80` → `CONTAINER_PORT=80`).
- **Entrypoint**: `nginx -g 'daemon off;'` serving static content from `/usr/share/nginx/html`.
- **Runner**: `ubuntu-latest` with Docker/Buildx available.
- **Required GitHub secrets**:
  - `AWS_REGION` — AWS region for all operations
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC (`id-token: write` permission)
  - `ECR_REPOSITORY_URL` — target ECR repository
  - `ECS_CLUSTER_NAME`, `ECS_SERVICE_NAME`, `ECS_TASK_FAMILY`, `CONTAINER_NAME` — ECS deployment targets
  - `PRODUCTION_APPROVERS` — GitHub usernames allowed to approve production deploys
- **AWS side**: An existing ECS cluster/service/task definition, an ECR repo, and an IAM deploy role trusting GitHub OIDC.
- **Tools installed in-flight**: Trivy, gitleaks v8.18.4, `jq` (preinstalled on runners).

## Pipeline Flow

```
security ─┐
          ├─► build ─► deploy-staging ─► deploy-production ─► post-deploy
test ─────┘                                        │
                                                   └─► (manual dispatch) rollback
```

### 1. Security Scans
Runs on every push and PR. Three independent checks:
- **Trivy** scans the filesystem for HIGH/CRITICAL vulnerabilities in dependencies — fails the job if found.
- **gitleaks** scans the working tree for committed secrets (redacted output, fails on detection).
- **CodeQL** performs static security analysis on JavaScript code; results are uploaded to the Security tab (`security-events: write`).

### 2. Unit and Integration Tests
Sets up Node 20, installs dependencies with `npm ci` (deterministic, lockfile-based), and runs tests with coverage. Coverage reports plus any `reports/` and `dist/` output are uploaded as artifacts for inspection.

### 3. Build, Scan and Push Image
Only runs for pushes to `main` or manual dispatch (skipped on PRs). After security and tests pass:
1. Assumes the AWS deploy role via OIDC and logs into ECR.
2. Builds the Docker image (nginx:alpine base) using GitHub Actions cache (`type=gha`) for speed.
3. Scans the built image with Trivy — HIGH/CRITICAL findings fail the pipeline before anything is pushed.
4. Pushes the image tagged with the commit SHA and `latest`.

### 4. Deploy to Staging
Fetches the current ECS task definition, swaps in the new image (SHA tag), and deploys to the ECS service, waiting for stability. If deployment fails, it automatically rolls back to the previously running task definition and prints recent service events for debugging.

### 5. Deploy to Production
Identical deploy process, but gated by a **manual approval** step: a GitHub issue is created and a listed approver must approve before AWS credentials are even configured. Same rollback-on-failure behavior as staging.

### 6. Post Deploy Verification
Confirms the ECS service reaches a stable state and prints desired vs. running task counts as a final health check.

### 7. Rollback (Manual)
Triggered only via `workflow_dispatch`. Computes the previous task definition revision and forces the service back to it, waiting for stability. Fails safely if no earlier revision exists.

## Key Design Points
- **Concurrency**: One run per branch — new pushes cancel in-progress runs.
- **OIDC auth**: No long-lived AWS keys; short-lived tokens via `id-token: write`.
- **SHA-tagged images**: Every deploy is traceable to an exact commit.
- **Defense in depth**: Dependency scan, secret scan, SAST, and image scan all gate the build.
- **Local runs**: Steps guarded by `ACT != 'true'` are skipped when running with [act](https://github.com/nektos/act) locally.

## Onboarding Tips
- To trigger a full deploy without a code change, use **workflow_dispatch** on `main`.
- If production deploy stalls, check the approval issue created by the `manual-approval` step.
- If a deploy fails, check the printed ECS service events table in the failed job log before re-running.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `CONTAINER_NAME`
- [x] `ECR_REPOSITORY_URL`
- [x] `ECS_CLUSTER_NAME`
- [x] `ECS_SERVICE_NAME`
- [x] `ECS_TASK_FAMILY`

Unresolved / failed to provision (add manually in GitHub before merging):
- [ ] `PRODUCTION_APPROVERS`
