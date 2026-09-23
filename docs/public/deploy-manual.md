---
title: deploy-manual.yml
sidebar_position: 7
description: The Actions button that deploys a chosen tag, without a second deploy implementation.
---

# `deploy-manual.yml`

A deploy you start by hand: pick an environment, a tag and optionally one service, press
**Run workflow**. It exists for the moments the release path does not cover — redeploy the tag
that is already live after a droplet was rebuilt, push a service back to yesterday's image, ship
from a phone.

It is **not** a second deploy implementation. The job installs the `sl` the calling repo pins in
its `package.json` and runs one `sl deploy`, exactly like [`app-release.yml`](./app-release.md)
does. What a deploy actually does — migrations, service order, workers, smoke, promote, the edge
and the monitoring — comes from the app's `deploy/skylabs.yaml` descriptor and the CLI.

> Until 2026-09-14 four repos carried their own hand-rolled `deploy-manual.yml`: about 150 lines
> each of `appleboy/ssh-action` with a GHCR login, an isolated migrator run, a fixed path to
> `deploy-service.sh`, a worker restart, a smoke check and (in one) a rollback. None of them read
> the descriptor or `.last-good-tags`, so they drifted from the release path by construction.

## The caller

```yaml
name: Deploy Manual

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Target environment
        type: choice
        options: [qa, prod]
        default: qa
      service:
        description: One service, or empty for the whole app
        type: choice
        options: ['', myapp-api, myapp-web]
        default: ''
      tag:
        description: Image tag to deploy (e.g. v1.2.3)
        type: string
        required: true
      confirm:
        description: "For prod: type exactly 'prod'"
        type: string
        default: ''

jobs:
  deploy:
    uses: skylabs-digital/.github/.github/workflows/deploy-manual.yml@main
    with:
      environment: ${{ inputs.environment }}
      service: ${{ inputs.service }}
      tag: ${{ inputs.tag }}
      confirm: ${{ inputs.confirm }}
    secrets: inherit
```

The service dropdown lives in the caller because `workflow_call` has no `choice` type, and
because the services are the app's own. If the list drifts from the descriptor, `sl deploy`
rejects the name and prints the valid ones — it never deploys something that is not declared.

## Inputs

| Input | Default | What it does |
|---|---|---|
| `environment` | — (required) | `qa` or `prod`. It is both the `sl deploy` environment and the GitHub Environment of the job. |
| `tag` | — (required) | A release, `vX.Y.Z`. It is both the image tag and the git ref that is checked out. `latest`, `qa-stable` or a sha are refused by the gate. |
| `service` | `''` | One service name, or empty for the whole app. |
| `confirm` | `''` | Must be exactly `prod` when `environment: prod`. |
| `skip-migrate` | `false` | Full deploy without migrations (`sl deploy --skip-migrate`). |
| `rollback-on-failure` | `true` | On failure, roll back to the last promoted tag. Turn it off when you are deliberately deploying an older tag. |
| `node-version` | `24` | |
| `runner-labels` | `["self-hosted","linux","x64","skylabs"]` | |

Secrets are the ones the release pipeline uses and arrive through `secrets: inherit`:
`GHCR_TOKEN`, `DEPLOY_SSH_KEY`, `SOPS_AGE_KEY`, and `SEMANTIC_RELEASE_APP_ID` /
`SEMANTIC_RELEASE_PRIVATE_KEY` (a read-only token for the platform registry in `infra`).

## One service is not a small full deploy

With a `service`, `sl deploy` runs the helpers, the compose fragment and **that service only** —
no migrations, no edge registration, no monitoring. That is the targeted deploy the old manual
workflows performed, and it is the right shape for putting one container back on a known tag.

It also means **a per-service deploy never runs migrations**. A backend that needs its migrations
applied is a full-app deploy (leave `service` empty), which is also the only shape that
re-registers the edge and the monitor.

## Which ref gets deployed

The tag. The job checks out `ref: <tag>`, so the descriptor, the compose fragment and the
encrypted secrets pushed to the droplet are the ones of the release whose image is deployed.
Until 2026-09-23 it checked out the **Use workflow from** branch, and an emergency rollback to an
old tag dispatched from `main` shipped the old image with `main`'s compose and descriptor
(DEP-09). `sl` 1.36 and later refuse a checkout that is not the tag's, so this is also what lets
an app raise its `sl` pin.

**Use workflow from** must be the default branch or a `v*` tag; any other branch is refused by
the gate. The deploy job holds the deploy keys, so the caller that reaches it must be the
reviewed one (SEC-01). What gets deployed comes from the tag either way.

## The prod gate

A `guard` job — no `environment:`, so it costs nothing and wakes nobody — validates the
environment name, the tag (`vX.Y.Z`), the ref the run was dispatched from and, for prod, that
`confirm` is exactly `prod`. It fails **red**, not
`skipped`: a whole run in green with everything skipped reads as "deployed" from the Actions
list, which is the worst possible ending for a production deploy that did not happen.

The typed confirmation is the same gate `infra`'s `provision-env.yml` uses, and it stacks with
the prod GitHub Environment's own protection rules. The gate runs first so the environment's
reviewers are only asked about a deploy that is already well-formed.

## Concurrency

One run at a time per (environment, service), never cancelled mid-flight — cancelling between the
`up` and the promote leaves the droplet in a state nobody asked for. The release pipeline runs in
its own `release-*` group and can overlap with this one; the real mutual exclusion is the
per-app `flock` on the droplet, inside `sl deploy`.
