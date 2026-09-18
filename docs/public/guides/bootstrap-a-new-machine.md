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

1. Checks for `brew`, `node` (24 or later), `gh`, `sops` (**3.10 or later**) and `age`. For
   anything missing it says so and **asks** before installing it with brew; an `sops` that is
   merely too old is offered as an upgrade, because `sl auth init` refuses to run below 3.10 —
   that is the version from which sops can decrypt with an SSH key. It does not install Homebrew
   itself: that installer edits your shell profile, and this script never does.
2. `corepack enable`, which provides `yarn` (repos declare it in `packageManager`).
3. `gh auth status`. No session: `gh auth login`, asking for the two scopes the fleet needs and
   `gh` does not grant by default. A session whose token is missing one:
   `gh auth refresh -s <the missing one>`.
    - **`read:packages`** — without it, installing from GitHub Packages answers `403` (step 4).
    - **`admin:public_key`** — without it, `sl auth init` cannot upload your public key to your
      GitHub account (step 5). On a fresh Mac the key has just been generated, so it is never
      there yet and the upload is always attempted.

   These are the two steps nobody remembers, and each one costs an afternoon.
4. `npm install -g @skylabs-digital/cli@<pinned version>`, authenticated with the token
   `gh auth token` returns on your machine, at that moment.
5. `sl auth init`: enrolls you as an operator. Your identity is your GitHub account, your key
   is one of your own SSH keys — `~/.ssh/id_ed25519` by default; it asks which one if you have
   several, and generates one without a passphrase if you have none. There is no Skylabs key of
   its own and no pull request to merge. It uploads that key to your GitHub account if it is not
   there yet, asks infra to run the reconciler that reads the team and rewrites the registry,
   and waits until the registry lists you and CI has re-encrypted the secrets for your key.

The approval is being in the **`skylabs-digital/operators`** team. If you are not in it yet,
`sl auth init` tells you who to ask and exits without touching anything.

Until the registry lists you and CI re-encrypts the secrets for your key, **your key decrypts
nothing** — on purpose: otherwise anyone running `sl auth init` could read the fleet's secrets.

Once that is done — `sl doctor` tells you — each repo is one command away:

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
