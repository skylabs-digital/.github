---
title: lib-release.yml
sidebar_position: 4
description: The library pipeline — CI, mutation, security and semantic-release to GitHub Packages.
---

# `lib-release.yml`

The release pipeline for **npm libraries**: `ci` and `security` on every pull request; on a push
to `main`, also `release`, which runs semantic-release and publishes to GitHub Packages.

```mermaid
flowchart LR
    CI["ci<br/>typecheck, lint, test, build"] --> R{"release<br/>push to main only"}
    MU["mutation<br/>Stryker, informative"] --> R
    SEC["security<br/>security.yml@v1"] --> R
    R --> P[("GitHub Packages")]
```

## Jobs

| Job | Runs on | What it does |
|---|---|---|
| `ci` | pull requests and pushes | `yarn install --immutable`, `yarn typecheck`, `yarn lint`, `extra-ci-steps`, `yarn test --coverage`, `yarn build`, `extra-ci-steps-post-build`. |
| `mutation` | pull requests and pushes, when `run-mutation` | `yarn test:mutation` (or `yarn mutation`) with Stryker's incremental state cached per branch. **Informative:** a low score writes a warning and a summary, never fails the job. |
| `security` | every event | [`security.yml@v1`](./security.md) without images. |
| `release` | push to `main` | The **fork point**. Builds and runs semantic-release: version from conventional commits, `CHANGELOG.md`, publish, GitHub release. |

`release` runs when nothing upstream failed — `mutation` may be skipped or below threshold and
the release still goes out; a real `ci` or `security` failure blocks it.

:::note The reusable does not run `yarn ci`
`ci` runs fixed steps, so a gate you add to your own `ci` script (a spec check, a dual-format
smoke test) exists in your pre-push hook and nowhere in CI. Declare it with `extra-ci-steps` (runs
after lint, before tests) or `extra-ci-steps-post-build` (runs after the build, when `dist/`
exists).
:::

## Inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `node-version` | string | `24` | Node for every job. |
| `build-tool` | string | `tsc` | Informational (`tsc`, `tsup`, `tsdown`, `vite`); the job always runs `yarn build`. |
| `run-mutation` | boolean | `true` | Run the `mutation` job. |
| `extra-ci-steps` | string | `''` | Shell run inside `ci` after lint and before tests. Empty = skipped. |
| `extra-ci-steps-post-build` | string | `''` | Shell run inside `ci` after the build. Empty = skipped. |
| `coverage-floor` | number | `90` | **Deprecated.** Accepted for compatibility; nothing reads it. Enforce coverage in the library's vitest config. |

Secrets, all optional through `secrets: inherit`: `GHCR_TOKEN` (installs), and
`SEMANTIC_RELEASE_APP_ID` / `SEMANTIC_RELEASE_PRIVATE_KEY` (the App token that pushes the release
commit and tag). The publish itself authenticates with the job's `GITHUB_TOKEN`, which is why
the caller grants `packages: write`.

## What the library provides

- Scripts: `typecheck`, `lint`, `test`, `build`; `test:mutation` or `mutation` for Stryker.
- A semantic-release configuration with `branches: ["main"]` and the npm, changelog, git and
  github plugins. The git plugin commits `chore(release): x.y.z [skip ci]`.
- `publishConfig.registry: https://npm.pkg.github.com`.

## When `main` moves during a release

The release commit is pushed in semantic-release's `prepare` step, **before** `publish`, so a
rejected push published nothing. The job then checks whether `main` moved: if it did, it resets
to the fresh `main`, reinstalls, rebuilds and lets semantic-release compute the version again —
up to three times. If `main` did not move, the failure is real and it stops.
