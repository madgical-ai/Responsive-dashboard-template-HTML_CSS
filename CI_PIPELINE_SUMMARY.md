# CI/CD Pipeline Walkthrough

This repository ships a container image to Amazon ECR and runs it on ECS Fargate, with a staging gate before production. The workflow lives in `.github/workflows/` and is named **CI/CD Pipeline**.

## Prerequisites

### Application runtime & container
- **Base image:** `nginxinc/nginx-unprivileged:1.27-alpine` (non-root, unprivileged nginx).
- **Exposed port:** `80` (container listens on 80; the unprivileged image does not require root).
- **Entrypoint:** `CMD ["nginx", "-g", "daemon off;"]` — the container must stay in the foreground.
- **Dockerfile location:** repository root (`./Dockerfile`). The `validate` job fails the build if it is missing.
- **Build args:** none declared. If you add any, wire them into both the `test` and `build` `docker build` invocations.

### Environment variables
- `NGINX_PORT` — set in the Dockerfile; the image must serve on port 80 to match the workflow's port mapping.
- Workflow-level: `IMAGE_TAG` (`github.sha`), `AWS_REGION` (`us-east-1`), `HEALTHCHECK_PATH` (`/`), `HOST_PORT` (`80`), `CONTAINER_PORT` (`80`).
- `ACT` — when set to `true` (local `act` runs), steps that need Docker networking or a live ALB are skipped.

### Runner requirements
- `ubuntu-latest` GitHub-hosted runners with Docker, Docker Buildx, `bash`, `curl`, `jq`, and `find` available.
- No self-hosted runner labels are used.

### Required secrets
| Secret | Used by |
| --- | --- |
| `ECR_REPOSITORY_URL` | build, publish, deploy |
| `AWS_DEPLOY_ROLE_ARN` | publish, deploy, rollback (OIDC assume-role) |
| `ECS_TASK_FAMILY` | deploy, rollback |
| `CONTAINER_NAME` | deploy (container to re-image in the task definition) |
| `ECS_SERVICE_NAME`, `ECS_CLUSTER_NAME` | deploy, rollback |
| `ALB_DNS_NAME` | staging/production health + smoke tests |
| `GITHUB_TOKEN` | Gitleaks secret scan (provided automatically) |

### AWS & GitHub configuration
- An **ECR repository** matching `ECR_REPOSITORY_URL`.
- An **ECS Fargate cluster and service**, plus an **ALB** whose DNS name is reachable from GitHub runners.
- An **IAM OIDC provider** for GitHub Actions and a deploy role trusting this repository (`id-token: write` is granted to publish/deploy/rollback).
- GitHub **environments** named `staging` and `production` (add protection rules/reviewers as needed).
- A repository language supported by CodeQL — currently configured as `javascript-typescript`.

## Pipeline stages

### 1. Quality gate (runs on every PR and push)
- **`validate`** — checks out the repo, asserts `Dockerfile` exists, and runs `bash -n` over every `*.sh` file to catch shell syntax errors. Uploads `reports/**` and `dist/**` if present.
- **`test`** — builds the image as `ci-test-image:<sha>`, runs it detached on host port `8080` → container port `80`, then polls `http://localhost:8080/` for up to 30 seconds. On failure it dumps container logs. The container is always removed, and a `test-report.txt` artifact is uploaded.

### 2. Security gate (runs in parallel with the quality gate)
- **`security-dependency-scan`** — Trivy filesystem scan of the repo; fails on `CRITICAL` or `HIGH` findings.
- **`security-secret-scan`** — Gitleaks over full history (`fetch-depth: 0`) with `--verbose --redact`.
- **`security-code-scan`** — CodeQL init + analyze for `javascript-typescript`, uploading results to GitHub code scanning (`security-events: write`).

### 3. Build & publish (push / manual dispatch only)
- **`build`** — waits on all five jobs above. Sets up Buildx, builds the image tagged both `<sha>` and `latest`, scans the built image with Trivy (fails on CRITICAL/HIGH), saves it to `image.tar.gz`, and uploads it as a 1-day artifact along with the scan report.
- **`publish`** — downloads the image artifact, loads it, assumes the AWS role via OIDC, logs in to ECR, and pushes both tags.

### 4. Staging
- **`deploy-staging`** — pulls the current ECS task definition, strips read-only fields with `jq`, renders a new revision pointing at the `<sha>` image, and deploys with `wait-for-service-stability: true`. On failure it prints the last 10 ECS service events.
- **`staging-health-check`** and **`staging-smoke-test`** — run in parallel after deploy; both poll `http://<ALB_DNS_NAME>/` (30 attempts, 5s apart) to confirm the service is live.

### 5. Production
- **`deploy-production`** — gated on both staging checks passing and on the `production` environment. Same render-and-deploy flow as staging.
- **`production-health-check`** and **`production-smoke-test`** — same checks against the production ALB.
- **`post-deploy`** — a final request to `/` to confirm the service is still serving after the deploy settles.

### 6. Failure handling
- **`rollback`** — runs only when a production job fails. It finds the second-newest ACTIVE task definition in the family, points the ECS service at it with `--force-new-deployment`, and waits for stability. Note it has no environment gate, so it executes without approval.

## How the stages connect

```
validate ─┐
test ─────┼─► build ─► publish ─► deploy-staging ─┬─► staging-health-check ─┐
sec-dep ──┤                                       └─► staging-smoke-test ────┼─► deploy-production ─┬─► production-health-check ─┐
sec-sec ──┤                                                                   │                      └─► production-smoke-test ───┼─► post-deploy
sec-code ─┘                                                                   │                                                    │
                                                                              └──────────────► rollback (on failure) ◄────────────┘
```

Everything before `build` runs on pull requests; `build` and later only run on pushes to `main` or manual dispatch. All jobs have a 30-minute timeout.

## Operational notes
- The `test` job name mentions unit/integration/coverage, but only a container smoke test is executed — add real test steps if you need coverage reporting.
- `ALB_DNS_NAME` is a single secret used by both staging and production checks. Scope it per environment (or use distinct secrets) so production verification cannot accidentally hit staging.
- `concurrency` with `cancel-in-progress: true` will cancel a running pipeline when a newer commit lands on the same ref — including a production deploy.
- Health checks use plain HTTP; consider HTTPS if the ALB terminates TLS.
- The image travels between `build` and `publish` as a gzipped artifact with 1-day retention. For faster pipelines, push directly to ECR from `build` instead.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `ALB_DNS_NAME`
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `CONTAINER_NAME`
- [x] `ECR_REPOSITORY_URL`
- [x] `ECS_CLUSTER_NAME`
- [x] `ECS_SERVICE_NAME`
- [x] `ECS_TASK_FAMILY`
