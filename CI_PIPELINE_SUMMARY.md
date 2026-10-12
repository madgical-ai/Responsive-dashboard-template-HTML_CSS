# CI/CD Pipeline Walkthrough

This pipeline validates, tests, scans, builds, deploys to AWS ECS Fargate, and auto-rolls-back on failure. It triggers on push/PR to `main` and cancels in-progress runs for the same ref.

## Prerequisites

- **Runtime:** Node.js 20 (installed via `actions/setup-node`, npm cache enabled)
- **Base image:** `nginx:alpine` (Dockerfile) — serves static content from `/usr/share/nginx/html`
- **System packages in image:** `curl`
- **Exposed port:** `80` (nginx)
- **Entrypoint:** `nginx -g 'daemon off;'` (foreground, container-friendly)
- **Runners:** `ubuntu-latest` for all jobs, 30-minute timeout each
- **Required GitHub secrets:**
  - `AWS_REGION` — AWS region for all AWS actions
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC (requires `id-token: write` permission)
  - `ECR_REPOSITORY_URL` — target ECR repo for image push
  - `ECS_CLUSTER_NAME`, `ECS_SERVICE_NAME`, `ECS_TASK_FAMILY`, `CONTAINER_NAME` — ECS deploy targets
- **AWS OIDC trust:** The deploy role must trust the GitHub OIDC provider for this repo.
- **Repo files:** `package.json` (Node steps are conditional on its presence), `Dockerfile` at repo root.

## Job-by-Job

### 1. Validate (lint, type-check)
Checks out code, installs dependencies with `npm ci`, and runs ESLint across the repo. The type-check step is currently a no-op placeholder — no type checker was detected.

### 2. Test (unit, integration, coverage)
Runs `npm run test:unit` and `npm run test:integration` (if defined), then `npm test -- --coverage`. Uploads `coverage/`, `test-results/`, `reports/`, and `dist/` as artifacts regardless of job outcome, so failures are debuggable.

### 3. Security (code, secret, dependency scan)
Three independent scans:
- **Semgrep** static analysis — *non-blocking* (`continue-on-error: true`).
- **Gitleaks** secret scanning — blocking; full git history is fetched (`fetch-depth: 0`).
- **Dependency audit** — `npm audit` (fails at HIGH+) or `pip-audit` if a `requirements.txt` exists.

### 4. Build and scan image *(push to main only)*
Runs after validate/test/security all pass. Assumes the AWS deploy role via OIDC, logs into ECR, builds the Docker image tagged with the commit SHA, scans it with **Trivy** (fails on CRITICAL/HIGH findings), then pushes both the SHA tag and `latest`.

### 5. Deploy to ECS Fargate *(push to main only)*
Downloads the current ECS task definition, swaps in the newly pushed image for the target container, and deploys via `amazon-ecs-deploy-task-definition`, waiting for service stability. On failure, dumps the last 10 service events and task stop reasons for debugging.

### 6. Rollback on failed deployment
Triggered only if deploy fails. Looks up the current task definition revision, computes `revision - 1`, and forces a new deployment with that previous revision, waiting for stability. Fails explicitly if no prior revision exists.

### 7. Post deploy
Prints a status table of the ECS service (status, running/desired counts, task definition) as a final confirmation.

## How the Stages Connect

```
PR/push → validate ─┐
         → test ─────┼→ build → deploy → post-deploy
         → security ─┘              ↘ (on failure) rollback
```

- **PRs** run only validate/test/security — fast feedback without AWS access.
- **Pushes to main** run the full chain through deploy.
- Build, deploy, rollback, and post-deploy all authenticate via **OIDC** (no long-lived AWS keys).
- The image tag is the commit SHA, giving full traceability from ECS task definition back to the exact commit.

## Known Gaps
- Type-check step is a placeholder.
- Semgrep findings don't fail the pipeline.
- Rollback's `revision - 1` logic can misfire if revisions were created outside this pipeline.
- Duplicate artifact upload steps upload the same `reports/**` and `dist/**` paths twice.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `CONTAINER_NAME`
- [x] `ECS_CLUSTER_NAME`
- [x] `ECS_SERVICE_NAME`
- [x] `ECS_TASK_FAMILY`

Unresolved / failed to provision (add manually in GitHub before merging):
- [ ] `ECR_REPOSITORY_URL`
