---
title: foreign-timezone.yml
sidebar_position: 8
description: The whole test suite once more under a timezone that is neither UTC nor ART.
---

# `foreign-timezone.yml`

Runs a repo's test suite again with the process clock in **`Asia/Tokyo`**, a zone that is
neither production's (UTC) nor the business's (`America/Argentina/Buenos_Aires`). It is the
minimum a repo needs to satisfy rule R8 of the fleet standard *Locale, currency and time*.

## Why a foreign zone

A test that computes a date the wrong way and asserts it the same wrong way passes. Whether the
two ways disagree depends on the zone the process runs in:

- **Under UTC the bug class is invisible.** A local getter and its UTC twin return the same
  number, a timestamp with no offset parses to the instant it denotes, and a calendar day never
  crosses a boundary. Production is UTC, so pinning UTC "to match production" is the one choice
  that finds nothing.
- **Under ART it is invisible to the team**, which works in ART.
- **`Asia/Tokyo`** (UTC+9) is 9 hours from production and 12 from the business, so for part of
  every day the calendar date differs from both. It has no daylight saving time, so a red run is
  a real bug.

appoint found two real bugs this way (a "next Monday" computed with local getters, and a
timestamp without an offset parsed in the process's zone). resuelto shipped about ten to
production with suites that ran green under both UTC and ART.

## The `pool: 'threads'` trap

Setting `test: { env: { TZ } }` in a Vitest config does **not** move the clock when the pool is
`threads`: Vitest applies it inside the worker thread, and Node only re-reads the zone when `TZ`
changes on a process's main thread. `process.env.TZ` reads back as `Asia/Tokyo` while
`new Date()` stays on the host's zone, so the suite looks pinned and is not.

This workflow sets `TZ` in the **job's** environment, which every process and thread inherits
before it starts, so it works under any pool. It also refuses to trust the variable: before
installing anything it renders two fixed instants and fails if the wall clock is not where `TZ`
says it is, or if the chosen zone matches UTC or ART at any time of year.

## Caller

```yaml
name: Timezone
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: timezone-${{ github.ref }}
  cancel-in-progress: true
jobs:
  foreign-timezone:
    uses: skylabs-digital/.github/.github/workflows/foreign-timezone.yml@main
    with:
      test-command: yarn test
    secrets: inherit
```

## Inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `time-zone` | string | `Asia/Tokyo` | IANA zone for the run. Rejected if it matches UTC or `America/Argentina/Buenos_Aires` at any time of year. |
| `test-command` | string | `yarn test` | The suite. |
| `setup-command` | string | `''` | Shell run after install and before the tests, e.g. building the workspaces the tests import. Empty = skipped. |
| `node-version` | string | `24` | Node for the job. |
| `runner-labels` | string | `["self-hosted","linux","x64","skylabs"]` | JSON array of runner labels. |
| `timeout-minutes` | number | `30` | Job timeout. |

Secret, optional through `secrets: inherit`: `GHCR_TOKEN`, for the `@skylabs-digital/*` install.

## This is the minimum, not the goal

The better adoption is to pin the zone as the **default of every Vitest config**, the way
resuelto does: assign `process.env.TZ` while the config module is evaluated (on the main thread),
declare it in `test.env` as well, and load a setup file that compares wall clocks in every
worker. The pin then runs on every local `yarn test` and in the pre-push hook, at no extra cost.
A repo that has done that does not need this job.
