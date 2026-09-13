# 🔁 skylabs-digital/.github

> The reusable release, security and docs pipelines every repo calls.

| | |
|---|---|
| 🧱 **Repo type** | Org reusable workflows and the new-machine bootstrap (public) |
| 🏷️ **Version** | Consumed at `@main` (release, docs) and `@v1` (`security.yml`) |
| 🚦 **Status** | 🟢 Stable — every app and library in the org releases through it |
| 📚 **Docs** | [docs.skylabs.digital/workflows](https://docs.skylabs.digital/workflows/) |

## ✨ What it does

Each Skylabs repo has a thin `.github/workflows/release.yml` that declares its triggers and
permissions and hands the pipeline to one of these reusables:

| Workflow | For | Stages |
|---|---|---|
| `app-release.yml` | apps | static checks · security · version bump · image build · `sl deploy` · config as code · secret rotation |
| `lib-release.yml` | libraries | CI · mutation (informative) · security · semantic-release to GitHub Packages |
| `security.yml` | everyone (called by the two above) | OSV-Scanner · Gitleaks · Grype · weekly rolling issue |
| `docs-publish.yml` | every repo with `docs/public/` | announce the section (`sl cac apply`) · publish the pages (`sl docs sync`), with its own pinned `sl` and the job's OIDC token |

The **FULL / REDUCED** fork lives inside each reusable: pull requests get checks and security;
a push to `main` also versions, publishes or builds, and deploys. Third-party actions are
SHA-pinned here, so every caller inherits the hardening.

Two traps worth knowing before you touch a reusable:

- **A reusable job that requests a permission its caller did not grant makes the whole run fail
  at startup**, on every event. Reusables declare no `permissions:` of their own and only ever
  reduce at job level.
- **An app caller must declare `repository_dispatch: skylabs-operators-changed`** and split its
  `concurrency.group` for that event, or it never re-encrypts its secrets when an operator
  leaves — and nothing warns you.

## 🚀 Quick start

A new machine, once:

```bash
curl -fsSL https://raw.githubusercontent.com/skylabs-digital/.github/main/bootstrap.sh | bash
```

Read it first (`… | less`): it checks brew, node, gh, sops and age and asks before installing
anything, adds the `read:packages` scope to your `gh` token, installs a **pinned** version of the
`sl` CLI, and runs `sl auth init`. It writes no secret and touches no shell profile.

A library's caller:

```yaml
jobs:
  release:
    uses: skylabs-digital/.github/.github/workflows/lib-release.yml@main
    with:
      node-version: "24"
      run-mutation: true
    secrets: inherit
```

An app's caller:

```yaml
jobs:
  release:
    uses: skylabs-digital/.github/.github/workflows/app-release.yml@main
    with:
      deploy-env: qa
      node-version: "24"
    secrets: inherit
```

Full callers (triggers, concurrency, permissions), every input and the stage-by-stage
walkthrough are on the [docs site](https://docs.skylabs.digital/workflows/).

## 🧑‍💻 Development

- Workflows live in `.github/workflows/`; `scripts/sync-dependabot.sh` generates each repo's
  security-only `dependabot.yml`; `bootstrap.sh` is served raw from `main`.
- `ci.yml` runs on pull requests touching workflows, scripts or `bootstrap.sh`: actionlint, a
  check for empty YAML mappings (they parse locally but GitHub rejects them as a "workflow file
  issue"), and shellcheck.
- A change to a reusable lands on every consumer at once (they track `@main`). Try it from a
  branch first by pointing one caller at `@<branch>`.
- A change to `bootstrap.sh` keeps its rules: readable header, pinned CLI, no secrets, no profile
  edits, nothing installed without asking, no `sudo`.

## 🚢 Releases

There is no release pipeline: merging to `main` publishes the release and docs reusables
immediately. `security.yml` is consumed at the `v1` tag, which is moved deliberately when a
change is ready for every repo.
