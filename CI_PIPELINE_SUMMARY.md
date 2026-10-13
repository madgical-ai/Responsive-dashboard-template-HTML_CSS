## Pipeline Walkthrough

This CI pipeline automates validation, testing, security scanning, image building, publishing, and staging validation for the project. It runs on pushes to `main` and pull requests targeting `main`. Concurrency settings cancel in-progress runs for the same workflow and ref.

## Prerequisites

Before CI can run successfully, ensure the following:

- **Runtime**: Node.js 20 (used for application linting and testing if configured). The workflow uses `actions/setup-node@v4` with `node-version: '20'`.
- **Docker base image**: `nginx:1.27-alpine` (from the Dockerfile). The build job creates an image from this base.
- **System packages**: None explicitly installed. The workflow relies on pre-installed tools on `ubuntu-latest` runners (Docker, curl, etc.). Hadolint, Trivy, and Gitleaks are provided via GitHub Actions.
- **Exposed ports**: The Dockerfile exposes ports `80` and `8080`. The staging-validation job maps host port `80` to container port `80` by default (via `HOST_PORT` and `CONTAINER_PORT` env vars). Ensure the application listens on port `80` for the health check to pass.
- **Required environment variables / secrets**:
  - `REGISTRY`: `ghcr.io` (set in workflow env)
  - `IMAGE_TAG`: `${{ github.sha }}` (set in workflow env)
  - `HOST_PORT`: `'80'` (set in workflow env)
  - `CONTAINER_PORT`: `'80'` (set in workflow env)
  - `GITHUB_TOKEN`: Automatically provided; used by Gitleaks and for GHCR login. Requires `packages: write` permission for the publish job.
- **Build args**: None specified in the Docker build command. If your Dockerfile requires build arguments, add them to the `docker build` step in the `build` job.

## Job Details

### Validate
Runs on `ubuntu-latest`. Steps:
1. Checkout repository.
2. Lint Dockerfile with Hadolint (failure threshold: error).
3. Detect linter configuration (`.eslintrc*` or `eslint.config.*`). If found, set up Node.js 20 and run `npx eslint .`. If not found, echo a message.

### Test
Runs on `ubuntu-latest`. Steps:
1. Checkout repository.
2. Detect test tooling: `package.json` with a `test` script (runner: npm) or `Makefile` with a `test` target (runner: make).
3. If npm: set up Node.js 20, cache npm dependencies (if `package-lock.json` exists), install dependencies (`npm ci` or `npm install`), run `npm test -- --coverage`.
4. If make: run `make test`.
5. If no test tooling: echo a message.
6. Always upload test results (`coverage/`, `junit.xml`, `test-results/`) and artifacts (`reports/**`, `dist/**`).

### Security - Dependency Scan
Runs on `ubuntu-latest`. Uses Trivy to scan the filesystem for vulnerabilities (CRITICAL, HIGH) with exit code 1 on findings.

### Security - Secret Scan
Runs on `ubuntu-latest`. Uses Gitleaks to scan for leaked secrets. Requires `GITHUB_TOKEN`.

### Build and Scan Image
Needs: validate, test, security-dependency-scan, security-secret-scan. Runs only on push to `main` or `workflow_dispatch`. Steps:
1. Checkout repository.
2. Set up Docker Buildx.
3. Resolve lowercase image name (`ghcr.io/owner/repo`).
4. Build Docker image with tags `${{ github.sha }}` and `latest`.
5. Scan image with Trivy (CRITICAL, HIGH, exit code 1).
6. Save image to tarball and upload as `docker-image` artifact.
7. Upload build artifacts (`reports/**`, `dist/**`).

### Publish Image
Needs: build. Runs only on push to `main` or `workflow_dispatch`. Permissions: `contents: read`, `packages: write`. Steps:
1. Download `docker-image` artifact.
2. Load image.
3. Resolve lowercase image name.
4. Log in to GHCR using `GITHUB_TOKEN`.
5. Push both tags (`${{ github.sha }}` and `latest`).
6. Upload artifacts.

### Staging - Container Health and Smoke Test
Needs: build. Runs only on push to `main` or `workflow_dispatch`. Steps:
1. Download `docker-image` artifact.
2. Load image.
3. Resolve lowercase image name.
4. Run container in detached mode, mapping host port 80 to container port 80.
5. Wait for health endpoint `/healthz` (up to 60 seconds).
6. Smoke test homepage `/`.
7. Stop and remove container.
8. Print logs on failure.
9. Upload artifacts.

## Flow and Connections

On pull requests, only **Validate**, **Test**, and the two **Security** jobs run. On pushes to `main`, after those pass, **Build and Scan Image** runs. Then **Publish Image** and **Staging Validation** run in parallel (both depend on build). Publish pushes the image to GHCR; staging validation runs the container to verify health and basic functionality.

## Artifacts

- `test-results`: coverage, junit.xml, test-results/
- `test-artifacts`: reports/**, dist/**
- `docker-image`: image.tar
- `build-artifacts`, `publish-artifacts`, `staging-validation-artifacts`: reports/**, dist/**

Note: Several jobs upload the same paths (`reports/**`, `dist/**`), which may be redundant.

## Risks and Recommendations

- **PRs skip build and staging**: Consider adding a build-only job for PRs to catch build failures early.
- **Port mismatch**: The staging validation assumes the app listens on port 80. If your app listens on 8080, adjust `CONTAINER_PORT` or the Dockerfile.
- **Health endpoint**: Ensure `/healthz` exists; otherwise staging validation fails.
- **Workflow dispatch**: The workflow does not trigger on `workflow_dispatch` despite conditions checking for it. Add `workflow_dispatch:` to the `on:` block for manual runs.
- **No build caching**: Consider using `docker/build-push-action` with cache to speed up builds.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
