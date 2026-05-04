# skylabs-digital/.github

Org-wide defaults and reusable workflows for Skylabs Digital.

## Reusable workflows

### `security.yml` — Security Scan

Standardized security scanning: dependency vulnerabilities (OSV), secrets in git history (Gitleaks), and container image vulnerabilities (Grype).

**Design choices for minimal noise:**
- `docker-scan` runs **only** on `push:main` and the weekly `schedule` — never on PRs. PR coverage comes from `osv-scan` over lockfiles.
- No `permissions:` block in the reusable — permissions inherit from the caller, avoiding cross-repo escalation and startup failures.
- `osv-scan` and `secrets-scan` are fast (<30 s combined); safe to run on every matching PR.

---

## Caller templates

### Template 1 — Node app + Docker (deployed services)

For: `resuelto`, `noten`, `idachu`, `skylabs-mcp`, `kommi`

```yaml
# .github/workflows/security.yml
name: Security
on:
  push: { branches: [main] }
  pull_request:
    paths:
      - '**/package.json'
      - '**/yarn.lock'
      - '**/package-lock.json'
      - '**/Dockerfile*'
      - '.github/workflows/**'
  schedule: [{ cron: '0 6 * * 1' }]

concurrency:
  group: security-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
    with:
      docker-images: |
        [
          {"name":"myapp-api","context":".","dockerfile":"backend/Dockerfile"}
        ]
    secrets:
      # Only needed if Dockerfiles use --mount=type=secret,id=npm_token
      # (for private @skylabs-digital packages from GHCR npm registry)
      npm-token: ${{ secrets.GHCR_TOKEN }}
```

### Template 2 — Node library / frontend (no Docker)

For: `react-identity-access`, `analytics`, `react-proto-kit`, `menu-engine`, `appoint-mvp`, `appoint`, `plato`, `cashier`, `fisto`, `wedding-app-fe`

```yaml
name: Security
on:
  push: { branches: [main] }
  pull_request:
    paths:
      - '**/package.json'
      - '**/yarn.lock'
      - '**/package-lock.json'
      - '.github/workflows/**'
  schedule: [{ cron: '0 6 * * 1' }]

concurrency:
  group: security-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
```

### Template 3 — Infra / config (gitleaks only)

For: `infra` (Terraform/config repos with no package.json)

```yaml
name: Security
on:
  push: { branches: [main] }
  pull_request:
  schedule: [{ cron: '0 6 * * 1' }]

concurrency:
  group: security-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
    with:
      gitleaks-only: true
```

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `docker-images` | string (JSON) | `'[]'` | Array of `{name, context, dockerfile}` for Grype scan |
| `gitleaks-only` | boolean | `false` | Skip OSV-Scanner (non-Node repos) |
| `osv-scan-args` | string | `--recursive ./` | Override OSV-Scanner args |

## Secrets

| Name | Required | Description |
|---|---|---|
| `npm-token` | no | Injected as `--mount=type=secret,id=npm_token` into Docker builds. Needed for private `@skylabs-digital` npm packages. |

## Tools & versions

- **OSV-Scanner** v2.3.5 — dependency vulnerabilities (npm, Docker lockfiles, etc.)
- **Gitleaks** v8.30.1 — secrets in code + git history (arch-aware install)
- **Grype** v0.111.1 — container image vulnerabilities, honors `.grype.yaml` in caller

## Versioning

- Pin to `@v1` for stability
- Breaking changes → `@v2`

---

# Dependabot template

`dependabot.yml` cannot be inherited from this org `.github` repo (GitHub limitation: only issue/PR templates and a few other files inherit). The canonical templates below are the source of truth; apply them with `scripts/sync-dependabot.sh` (one-shot, see below).

## Behaviour summary

- **Routine version updates** (weekly): only `patch` and `minor` for npm and docker. No major bumps.
- **Security updates**: GitHub Dependabot opens separate PRs labeled `security` when a CVE matches your lockfile. These bypass the `dependabot.yml` `ignore` rules and propose the minimum patched version (which can be a major if no patch/minor fix exists). Requires `vulnerability-alerts` and `automated-security-fixes` enabled at the repo level.

## Template T1 — Node + Docker monorepo

For repos with one or more Dockerfiles and yarn workspaces (e.g. `resuelto`, `noten`, `idachu`, `kommi`, `skylabs-mcp`).

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    groups:
      actions:
        patterns: ["*"]

  # One docker block per Dockerfile dir. Major bumps blocked here; security
  # advisories from GitHub still bypass these rules and may bump majors.
  - package-ecosystem: docker
    directory: /backend
    schedule: { interval: weekly }
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]
    groups:
      docker:
        patterns: ["*"]

  # ... repeat the docker block for each Dockerfile dir (frontend/, backoffice/, etc.)

  # One npm block per workspace dir. update-types restricted to patch+minor.
  - package-ecosystem: npm
    directory: /
    schedule: { interval: weekly }
    open-pull-requests-limit: 5
    groups:
      dev-deps:
        dependency-type: development
        update-types: [patch, minor]
      prod-deps:
        dependency-type: production
        update-types: [patch, minor]

  # ... repeat the npm block for each workspace (backend/, frontend/, backoffice/)
```

## Template T2 — Single-package Node lib / FE

For libs and single-package apps (e.g. `analytics`, `react-identity-access`, `react-proto-kit`, `menu-engine`, `appoint-mvp`, `appoint`, `plato`, `cashier`, `fisto`, `wedding-app-fe`).

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    groups:
      actions:
        patterns: ["*"]

  - package-ecosystem: npm
    directory: /
    schedule: { interval: weekly }
    open-pull-requests-limit: 5
    groups:
      dev-deps:
        dependency-type: development
        update-types: [patch, minor]
      prod-deps:
        dependency-type: production
        update-types: [patch, minor]
```

## Template T3 — Infra / config (no node, no docker build)

For `infra` and similar.

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    groups:
      actions:
        patterns: ["*"]
```

## Applying the template

```bash
# In the .github repo
./scripts/sync-dependabot.sh /path/to/repo

# Or to dry-run
./scripts/sync-dependabot.sh --dry-run /path/to/repo
```

The script auto-detects:
- Dockerfile dirs (any dir containing `Dockerfile*`) → adds a docker block
- npm workspace dirs (any dir with `package.json` not in `node_modules`) → adds an npm block

If the repo has neither, it falls back to T3 (github-actions only).

## Enabling security updates

After applying, enable at the repo level:

```bash
gh api -X PUT /repos/skylabs-digital/<repo>/vulnerability-alerts
gh api -X PUT /repos/skylabs-digital/<repo>/automated-security-fixes
```

Verify:

```bash
gh api /repos/skylabs-digital/<repo>/automated-security-fixes
# → {"enabled": true, "paused": false}
```

