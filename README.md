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
