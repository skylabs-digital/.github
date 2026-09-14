---
title: Bootstrap a new machine
sidebar_position: 2
description: The one-line setup that leaves a new Mac with sl, and the rules that keep it safe.
---

# Bootstrap a new machine

`bootstrap.sh` lives in this repo because it is the org's only public one: a new laptop can
fetch it before it has any credentials. Run it **once per machine**:

```bash
curl -fsSL https://raw.githubusercontent.com/skylabs-digital/.github/main/bootstrap.sh | bash
```

Read it first — that is why it is public:

```bash
curl -fsSL https://raw.githubusercontent.com/skylabs-digital/.github/main/bootstrap.sh | less
```

macOS only. Do not run it with `sudo`; it refuses.

## What it does

Every step is idempotent: running it again reinstalls nothing.

1. Checks for `brew`, `node` (24 or later), `gh`, `sops` and `age`. For anything missing it says
   so and **asks** before installing it with brew. It does not install Homebrew itself: that
   installer edits your shell profile, and this script never does.
2. `corepack enable`, which provides `yarn` (repos declare it in `packageManager`).
3. `gh auth status`. No session: `gh auth login`. A session whose token lacks the
   **`read:packages`** scope: `gh auth refresh -s read:packages`. This is the step nobody
   remembers — the token `gh auth login` leaves does not include it, and without it installing
   from GitHub Packages answers `403`.
4. `npm install -g @skylabs-digital/cli@<pinned version>`, authenticated with the token
   `gh auth token` returns on your machine, at that moment.
5. `sl auth init`: generates your age and SSH identities, opens the onboarding pull request
   against the platform repo, and waits for the merge.

Until that pull request is merged and CI re-encrypts the secrets for your key, **your new key
decrypts nothing** — on purpose: otherwise anyone running `sl auth init` could read the fleet's
secrets.

After the merge, each repo is one command away:

```bash
git clone git@github.com:skylabs-digital/<repo>.git
cd <repo> && sl setup
```

If something is off: `sl doctor`. More in the [CLI's getting started](/cli/getting-started).

## The rules that make `curl | bash` acceptable

A piped script runs code nobody read, from a repo that becomes a way to run code on every
teammate's machine. Every pull request that touches `bootstrap.sh` must keep these:

| Rule | Why |
|---|---|
| `main` is protected (pull request, no force-push, no deletion) | Without it, the one-liner should not be published |
| Readable without running it: the header says what it does, installs and does **not** do | `curl <url>` alone must be enough to review it |
| The CLI is **pinned** to a version, never `latest` | A piped script that installs "the latest" is an automatic deploy channel to laptops |
| No secret inside | The token comes from `gh auth token` at run time; it is never written to a file or printed |
| It touches no shell profile | If something had to be exported, the CLI's design failed: `sl` injects credentials into the processes it launches |
| Nothing installs without asking, nothing runs with `sudo` | The default answer is **no**; the exact command is printed before it runs |

## Bumping the pinned CLI

The version is the `CLI_VERSION` variable near the top of `bootstrap.sh`. Raising it is a pull
request to this repo — which is exactly what makes what runs on the team's machines auditable.
The pull request runs shellcheck over the script (`ci.yml`).
