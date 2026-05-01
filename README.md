# skylabs-digital/.github

Org-wide defaults and reusable workflows for Skylabs Digital.

## Reusable workflows

### `security.yml` — Security Scan

Standardized security scanning: dependency vulnerabilities (OSV), secrets in git history (Gitleaks), and container image vulnerabilities (Grype).

**Usage — Node app + Docker (Template 1):**

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

jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
    with:
      docker-images: |
        [
          {"name":"myapp-api","context":".","dockerfile":"backend/Dockerfile"}
        ]
```

**Usage — Node library / frontend (Template 2, no Docker):**

```yaml
jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
```

**Usage — Infra / config repos (Template 3, gitleaks-only):**

```yaml
jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
    with:
      gitleaks-only: true
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `docker-images` | string (JSON array) | `'[]'` | Images to scan with Grype |
| `gitleaks-only` | boolean | `false` | Skip OSV-Scanner (for non-Node repos) |
| `osv-scan-args` | string | `--recursive ./` | OSV-Scanner override |

### Behavior

- **`osv-scan`** runs on all events (unless `gitleaks-only`)
- **`secrets-scan`** (gitleaks) runs on all events
- **`docker-scan`** runs **only on push & schedule** — never on PRs (too slow, PR coverage via osv-scan on lockfiles)
- Grype loads `.grype.yaml` from caller repo if present (for documented ignores)

## Versioning

- Pin to `@v1` for stability (SemVer major tag)
- Breaking changes bump to `@v2`
