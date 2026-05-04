#!/usr/bin/env bash
# sync-dependabot.sh — generate a standardized .github/dependabot.yml in a repo.
#
# Auto-detects:
#   - Dockerfile dirs (any dir with Dockerfile* not under node_modules/.git/dist/build)
#   - npm workspace dirs (any dir with package.json, same exclusions)
#
# Behaviour:
#   - Routine updates: patch + minor only (no majors)
#   - Security advisory PRs: bypass these rules and may bump to a major
#     (requires `vulnerability-alerts` and `automated-security-fixes` enabled)
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
    -not -path '*/.windsurf/*' \
    2>/dev/null \
    | xargs -I{} dirname {} \
    | sort -u \
    | sed 's|^\./||; s|^\.$|/|; s|^\([^/]\)|/\1|'
)

OUTPUT="version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    groups:
      actions:
        patterns: [\"*\"]
"

for d in "${DOCKER_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  OUTPUT+="
  - package-ecosystem: docker
    directory: $d
    schedule: { interval: weekly }
    ignore:
      - dependency-name: \"*\"
        update-types: [\"version-update:semver-major\"]
    groups:
      docker:
        patterns: [\"*\"]
"
done

for d in "${NPM_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  OUTPUT+="
  - package-ecosystem: npm
    directory: $d
    schedule: { interval: weekly }
    open-pull-requests-limit: 5
    groups:
      dev-deps:
        dependency-type: development
        update-types: [patch, minor]
      prod-deps:
        dependency-type: production
        update-types: [patch, minor]
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
