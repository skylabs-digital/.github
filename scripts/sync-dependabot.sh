#!/usr/bin/env bash
# sync-dependabot.sh — generate a standardized .github/dependabot.yml in a repo.
#
# Auto-detects:
#   - Dockerfile dirs (any dir with Dockerfile* not under node_modules/.git/dist/build)
#   - npm workspace dirs (any dir with package.json, same exclusions)
#
# Behaviour (security-only, low-noise — see docs/standards/dependabot-noise-policy.md):
#   - open-pull-requests-limit: 0  → NO routine version-update PRs.
#   - Security-update PRs still flow (exempt from the limit) for ALL deps, but
#     `ignore: version-update:semver-major` suppresses major bumps, so only
#     patch/minor vuln fixes auto-PR. Major fixes surface as Dependabot alerts +
#     the OSV CI warning (verify by hand).
#   - Requires org-level Dependabot alerts + security updates enabled.
#
# Private registry:
#   Repos that consume @skylabs-digital/* packages get a `registries:` block so
#   Dependabot can authenticate against GitHub Packages. Without it the updater
#   hits 401 "authentication token not provided" on every private tarball and
#   resolves the tree blind. The token comes from the ORG-LEVEL DEPENDABOT
#   secret GHCR_TOKEN (Dependabot has its own secret store — Actions secrets are
#   NOT visible to it). See docs/standards/dependabot-noise-policy.md.
#
# Usage:
#   sync-dependabot.sh [--dry-run] <repo-path>

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

REPO_PATH="${1:-}"
if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
  echo "Usage: $0 [--dry-run] <repo-path>" >&2
  exit 1
fi

cd "$REPO_PATH"

# Find Dockerfile directories. We index by directory (not file) and dedupe.
# Excludes node_modules, dist, build, .git, .next, .yarn.
# Uses while-read instead of mapfile for portability with bash 3.2 (macOS).
DOCKER_DIRS=()
while IFS= read -r line; do
  DOCKER_DIRS+=("$line")
done < <(
  find . -type f \( -name 'Dockerfile' -o -name 'Dockerfile.*' \) \
    -not -path '*/node_modules/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    -not -path '*/.git/*' \
    -not -path '*/.next/*' \
    -not -path '*/.yarn/*' \
    -not -path '*/.worktrees/*' \
    -not -path '*/.claude/*' \
    -not -path '*/.stryker-tmp/*' \
    -not -path '*/.windsurf/*' \
    2>/dev/null \
    | xargs -I{} dirname {} \
    | sort -u \
    | sed 's|^\./||; s|^\.$|/|; s|^\([^/]\)|/\1|'
)

# Find package.json directories (npm workspaces).
NPM_DIRS=()
while IFS= read -r line; do
  NPM_DIRS+=("$line")
done < <(
  find . -type f -name 'package.json' \
    -not -path '*/node_modules/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    -not -path '*/.git/*' \
    -not -path '*/.next/*' \
    -not -path '*/.yarn/*' \
    -not -path '*/.worktrees/*' \
    -not -path '*/.claude/*' \
    -not -path '*/.stryker-tmp/*' \
    -not -path '*/.windsurf/*' \
    2>/dev/null \
    | xargs -I{} dirname {} \
    | sort -u \
    | sed 's|^\./||; s|^\.$|/|; s|^\([^/]\)|/\1|'
)

# Detect consumption of private @skylabs-digital/* packages. Only dependency
# sections count — a lib whose own `name` is @skylabs-digital/* but that
# consumes nothing private needs no registry.
HAS_PRIVATE_DEPS=0
for d in "${NPM_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  pkg=".${d%/}/package.json"
  pkg="${pkg//\/\///}"
  [[ -f "$pkg" ]] || continue
  if node -e "
    const p = require('$PWD/${pkg#./}');
    const deps = {...p.dependencies, ...p.devDependencies, ...p.peerDependencies};
    process.exit(Object.keys(deps).some(d => d.startsWith('@skylabs-digital/')) ? 0 : 1);
  " 2>/dev/null; then
    HAS_PRIVATE_DEPS=1
    break
  fi
done

# npm entries reference the registry only when the repo consumes private deps.
NPM_REGISTRY_REF=""
REGISTRIES_BLOCK=""
if [[ $HAS_PRIVATE_DEPS -eq 1 ]]; then
  REGISTRIES_BLOCK="registries:
  npm-github:
    type: npm-registry
    url: https://npm.pkg.github.com
    token: \${{secrets.GHCR_TOKEN}}

"
  NPM_REGISTRY_REF="    registries:
      - npm-github
"
fi

OUTPUT="version: 2
${REGISTRIES_BLOCK}updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    open-pull-requests-limit: 0
    ignore:
      - dependency-name: \"*\"
        update-types: [\"version-update:semver-major\"]
"

for d in "${DOCKER_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  OUTPUT+="
  - package-ecosystem: docker
    directory: $d
    schedule: { interval: weekly }
    open-pull-requests-limit: 0
    ignore:
      - dependency-name: \"*\"
        update-types: [\"version-update:semver-major\"]
"
done

for d in "${NPM_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  OUTPUT+="
  - package-ecosystem: npm
    directory: $d
    schedule: { interval: weekly }
    open-pull-requests-limit: 0
${NPM_REGISTRY_REF}    ignore:
      - dependency-name: \"*\"
        update-types: [\"version-update:semver-major\"]
"
done

TARGET="$REPO_PATH/.github/dependabot.yml"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "=== Would write to $TARGET ==="
  echo "$OUTPUT"
  echo "=== Detected ${#DOCKER_DIRS[@]} docker dirs, ${#NPM_DIRS[@]} npm dirs ==="
else
  mkdir -p "$REPO_PATH/.github"
  echo "$OUTPUT" > "$TARGET"
  echo "Wrote $TARGET (${#DOCKER_DIRS[@]} docker dirs, ${#NPM_DIRS[@]} npm dirs)"
fi
