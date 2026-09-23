---
title: docs-publish.yml
sidebar_position: 6
description: Announce a repo's docs section and publish its pages after a release.
---

# `docs-publish.yml`

Every repo documents itself in `docs/public/`, announces its section with config as code in
`cac/docs.ts`, and publishes both from its own pipeline. `docs-publish.yml` does the two steps:

1. **Announce** — `sl cac apply --env prod --file cac/docs.ts --no-create-keys`: slug, name,
   group, icon, description and owner repo of the section, declared with
   `@skylabs-digital/docs-cac`.
2. **Publish** — `sl docs sync`: validates the folder `docs.dir` of `deploy/skylabs.yaml` and
   uploads it.

Both authenticate with the job's **GitHub Actions OIDC token** (audience
`docs.skylabs.digital`). Docs itself needs no secret; `GHCR_TOKEN` is only for installing the
private `@skylabs-digital/*` packages.

## Calling it

Add a `docs` job to `release.yml`, next to the job that calls the release reusable:

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

- `needs:` names the job that calls `app-release.yml` or `lib-release.yml`. The docs publish
  after a successful release, so what is published matches what shipped.
- `id-token: write` is granted **on this job only** — see below why this is a separate reusable.
- **A docs failure is red, and visible.** It is a job of its own after the release, so a red here
  never undoes a deploy — but it is no longer `continue-on-error`: that setting kept releases
  green while resuelto's docs did not publish for weeks (DEP-19).

A repo with no release workflow adds `.github/workflows/docs.yml` that calls the same reusable on
pushes to `main` touching `docs/public/**` or `cac/docs.ts`.

## What the job does

| Step | What |
|---|---|
| Checkout | `ref` (default `main`): after a release, the version bump is a later commit than the one that triggered the run, and the version shown on the docs status page comes from `package.json` |
| Detect | No `docs:` in `deploy/skylabs.yaml` → a notice and the job ends green. `docs:` declared but no `cac/docs.ts` → an error: docs were expected and none would go out |
| Install | `yarn install --immutable`, so `cac/docs.ts` can resolve its imports |
| Resolve `sl` | The repo's own pin (`yarn sl`) when it has one ≥ 1.21.0; otherwise `@skylabs-digital/cli@<cli-version>`, or 1.37.0, into `$RUNNER_TEMP` |
| Announce | `sl cac apply --env prod --file <stack-file> --no-create-keys` |
| Publish | `sl docs sync` |

`--env prod` because the section registry is global (one docs site for every environment) and the
protocol just requires one. `--no-create-keys` because the stack has no keys, and a library has no
`deploy/secrets/` to write to.

## Inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `cli-version` | string | `''` | Force this `sl` version (1.21.0 or later: `auth: github`, `--no-create-keys` without a secrets destination, the version header). Empty: the repo's own pin, else 1.37.0. From 1.36.0 the `sl cac apply` step also requires a clean checkout of `main` (no tracked file modified by `yarn install`) |
| `stack-file` | string | `cac/docs.ts` | The stack that announces the section |
| `ref` | string | `main` | What to check out |
| `node-version` | string | `24` | Node for the job |
| `runner-labels` | string (JSON) | `["self-hosted","linux","x64","skylabs"]` | Where it runs |

Secret: `GHCR_TOKEN` (optional, through `secrets: inherit`).

## Which `sl`

The descriptor schema is strict: a descriptor written for a newer `sl` is rejected by an older
one. Until 2026-09-23 this job always ran its own 1.21.0, and resuelto's descriptor (which uses
`de:`, from 1.27) never published. So the job now runs **the repo's own pin** when there is one
that speaks `auth: github` (every app pins 1.22 or later): the `sl` that deploys the descriptor is
the one that reads it. A library without the cli pinned gets 1.37.0. A repo adopting docs only
adds `@skylabs-digital/docs-cac` as a devDependency (plus `@skylabs-digital/cac` if it does not
have it yet — 1.x or 2.x both work).

## Why a separate reusable

A called workflow cannot ask for a permission its caller did not grant: the whole run fails **at
startup**, before any job, even a job that would be skipped. App callers deliberately do not grant
`id-token: write` to their release. An OIDC job inside `app-release.yml` would have broken the
release of every app that had not granted it. Here the grant lives on the caller's `docs` job
only, and a repo opts in by adding the job. More in
[Permissions and startup failures](./guides/permissions-and-startup-failures.md).

## What the repo must have

| File | Contents |
|---|---|
| `docs/public/` | The pages, with an `index.md` |
| `deploy/skylabs.yaml` | `docs: { dir: docs/public }`. A library that does not deploy has a five-line descriptor with `kind: lib` just for this |
| `cac/docs.ts` | The section, declared with `new docs.Section(stack, { slug, name, group, icon, description, order?, repo })` |
| `package.json` | `@skylabs-digital/docs-cac` (and `@skylabs-digital/cac`) as devDependencies |

Before merging, from the repo with the global `sl`:

```bash
sl cac plan --env prod --file cac/docs.ts
sl docs sync --dry-run
```

:::note The `cac` core
`@skylabs-digital/docs-cac` peer-depends on `@skylabs-digital/cac`, so the `cac` repo cannot
install it on itself: its section is announced and published by hand, without this job.
:::
