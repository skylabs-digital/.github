---
title: Getting started
sidebar_position: 2
description: Wire a repo to the right reusable with a thin release.yml.
---

# Getting started

A repo adds one file, `.github/workflows/release.yml`, and picks the reusable that matches what
it ships. The file declares triggers, concurrency and permissions; the reusable does the rest.

## An app

Requirements: a deploy descriptor `deploy/skylabs.yaml`, `deploy/compose.yml`, the encrypted
`deploy/secrets/<env>.env`, and `@skylabs-digital/cli` as a devDependency. The service list,
the images to build and the deploy order all come from the descriptor.

```yaml
name: Release

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"
  repository_dispatch:
    types: [skylabs-operators-changed]

concurrency:
  group: release-${{ github.event_name == 'repository_dispatch' && 'secrets-rotate' || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: write
  packages: write
  id-token: write

jobs:
  release:
    uses: skylabs-digital/.github/.github/workflows/app-release.yml@main
    with:
      deploy-env: qa
      node-version: "24"
    secrets: inherit
```

Two lines are easy to drop and expensive to miss:

- **`repository_dispatch: skylabs-operators-changed`** is mandatory for every app whose secrets
  are encrypted for the operators. Without it the app never re-encrypts when an operator leaves,
  and nothing warns you: the dispatch API answers `204` even when no workflow listens.
- **The `concurrency.group` expression** puts the rotation in its own group. With a single
  `release-${{ github.ref }}` group, a merge to `main` during a rotation cancels the pending
  rotation silently.

An app that has no descriptor yet pins the pre-v2 branch instead:
`app-release.yml@legacy-services`.

## A library

```yaml
name: Release

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: write
  packages: write
  id-token: write
  issues: write # lets the weekly security run upsert its rolling issue

jobs:
  release:
    uses: skylabs-digital/.github/.github/workflows/lib-release.yml@main
    with:
      node-version: "24"
      build-tool: tsdown
      run-mutation: true
    secrets: inherit
```

The library must define `yarn typecheck`, `yarn lint`, `yarn test`, `yarn build` and a
semantic-release configuration (`.releaserc.json` or `release.config.*`), plus `test:mutation` or
`mutation` if it wants mutation testing.

## Publishing docs

Every repo with a `docs/public/` folder adds a `docs` job next to `release`:

```yaml
  docs:
    needs: release
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    uses: skylabs-digital/.github/.github/workflows/docs-publish.yml@main
    permissions:
      contents: read
      id-token: write
    secrets: inherit
```

`needs:` must match the name of the job that calls the release reusable. The job brings its own
`sl`, so the repo does not bump its `@skylabs-digital/cli` pin; it only adds
`@skylabs-digital/docs-cac` (and `@skylabs-digital/cac` if missing) as devDependencies. See
[docs-publish.yml](./docs-publish.md).

## A repo with no release pipeline

Call the security reusable on its own:

```yaml
name: Security

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: "0 6 * * 1"

concurrency:
  group: security-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  security:
    uses: skylabs-digital/.github/.github/workflows/security.yml@v1
    with:
      gitleaks-only: true # a repo without package.json
```

## Org secrets the reusables read

`secrets: inherit` passes the organization secrets through. None of them is set per repo.

| Secret | Used by | For |
|---|---|---|
| `GHCR_TOKEN` | all | Installing private `@skylabs-digital/*` packages (also inside Docker builds) |
| `SEMANTIC_RELEASE_APP_ID`, `SEMANTIC_RELEASE_PRIVATE_KEY` | all | The GitHub App token that pushes release commits and tags |
| `DEPLOY_SSH_KEY` | `app-release` | `sl deploy` |
| `SOPS_AGE_KEY` | `app-release` | Decrypting `deploy/secrets/<env>.env`; re-encrypting on rotation |
| `INFRA_READ_TOKEN` | `app-release` | Read-only sparse checkout of the platform registry (falls back to `GHCR_TOKEN`) |
| `IDACHU_CAC_KEY` | `app-release` | Config as code, per GitHub Environment |

A GitHub App token cannot read npm tarballs from GitHub Packages (it answers `403`), which is
why package installs use the `GHCR_TOKEN` classic PAT and not the App token.
