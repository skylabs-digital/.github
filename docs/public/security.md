---
title: security.yml
sidebar_position: 5
description: OSV-Scanner, Gitleaks and Grype with a fixability gate, and a weekly rolling issue.
---

# `security.yml`

The org security scan. `app-release.yml` and `lib-release.yml` call it for you; a repo with no
release pipeline calls it directly. It is consumed at `@main`, like the rest of the reusables. The `v1` tag is frozen at 2026-09-02 and no longer consumed.

## Jobs

| Job | Runs | What it scans |
|---|---|---|
| `osv-scan` | every event, unless `gitleaks-only` | Dependency lockfiles with OSV-Scanner 2.3.5. |
| `secrets-scan` | every event | The whole git history with Gitleaks 8.30.1 (checksum-verified install). |
| `docker-scan` | push and schedule only, when `docker-images` is not empty | Builds each image locally and scans it with Grype 0.111.1. Never on pull requests: images are expensive and lockfiles already cover PRs. |
| `weekly-security-report` | schedule only | Upserts one rolling issue per repo, labelled `weekly-security-review`, with the OSV summary. |

## The gate: fixable findings only

OSV and Grype both run non-blocking and write JSON; a gate step then decides.

- **Block** only when a finding is **fixable** (a patched version exists) **and** its severity is
  at or above the threshold.
- **Warn** for everything else — no fix yet, or below the threshold. Nothing is dropped
  silently: every finding is listed in the job summary.

When it blocks depends on `gate-mode`:

| `gate-mode` | Behaviour |
|---|---|
| `auto` (default) | Block on `push`; report on `pull_request` and `schedule`. A push to `main` is about to deploy; a PR's findings are usually not the PR's. |
| `block` | Always block on blocking findings. |
| `report` | Never fail; findings go to the summary and annotations. |

**A scanner that produced no result is not a clean result.** In block mode (a push to `main`),
an OSV-Scanner run with no results file, results that do not parse, or a Grype that exits
non-zero fail the job; in report mode they are a warning (DEP-18).

**Gitleaks always blocks**, whatever the mode: a leaked secret stays leaked. Suppress confirmed
false positives in the calling repo with a `.gitleaks.toml` allowlist (passed with `-c`) or
fingerprints in `.gitleaksignore`. The `.gitleaks.toml` **must start with**

```toml
[extend]
useDefault = true
```

or it replaces the default rules instead of extending them — an allowlist-only file means zero
rules and a check that is green forever. The job fails on such a file (SEC-21). Grype honours a
`.grype.yaml` in the calling repo.

Gitleaks and Grype are downloaded from their GitHub releases with a pinned SHA-256 into the job's
`$RUNNER_TEMP`: no `curl | sh`, no `sudo`, nothing left in `/usr/local/bin` of a shared runner.

## Inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `docker-images` | string (JSON) | `'[]'` | `[{ "name", "context", "dockerfile" }]` to build and scan. Extra keys are ignored. |
| `gitleaks-only` | boolean | `false` | Skip OSV (and the weekly issue) for repos without a lockfile. |
| `osv-scan-args` | string | `--recursive ./` | OSV-Scanner targets. |
| `osv-fail-on-severity` | string | `critical` | `critical`, `high`, `medium` or `low`. |
| `grype-fail-on-severity` | string | `critical` | Same, for images. |
| `gate-mode` | string | `auto` | `auto`, `block` or `report`. |

## Secrets

| Secret | Meaning |
|---|---|
| `npm-token` | Mounted as the BuildKit secret `npm_token` when building images, for private `@skylabs-digital/*` packages. Pass `GHCR_TOKEN`. |
| `app-id`, `private-key` | When both are set, an ephemeral App installation token is used instead of `npm-token`. |

:::warning Do not forward the App credentials for Docker builds
An App installation token cannot read npm tarballs from GitHub Packages — it answers `403` and
the whole Grype matrix fails. The release reusables forward only `npm-token: GHCR_TOKEN` for
this reason, even though the secret's description calls `npm-token` deprecated.
:::

## Permissions

`security.yml` declares **no** `permissions:` block: every job inherits the caller's. A caller
typically grants `contents: read`. The weekly issue needs `issues: write`; without it the upsert
gets a `403` at runtime and `continue-on-error` keeps the run green. It must not be requested at
job level inside the reusable — see
[Permissions and startup failures](./guides/permissions-and-startup-failures.md).
