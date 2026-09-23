#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for the "sl version floor" step (DEP-08(3)).
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sl-floor-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT

# floor <workflow> <job> <pinned version or ""> <floor> — exit code.
floor() {
  local app="${WORK_ROOT}/app"
  rm -rf "$app"; mkdir -p "$app"
  if [ -n "$3" ]; then
    mkdir -p "$app/node_modules/@skylabs-digital/cli"
    printf '{ "name": "@skylabs-digital/cli", "version": "%s" }\n' "$3" > "$app/node_modules/@skylabs-digital/cli/package.json"
  fi
  extract_step "$1" "$2" "sl version floor" > "${WORK_ROOT}/floor.sh"
  set +e
  (cd "$app" && SL_MIN_VERSION="$4" run_step "${WORK_ROOT}/floor.sh") > "${WORK_ROOT}/log" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

for spec in "app-release.yml deploy" "app-release.yml cac-plan" "app-release.yml cac-apply" "deploy-manual.yml deploy"; do
  read -r wf job <<< "$spec"
  CURRENT_TEST="DEP-08 ${wf}:${job}"
  floor "$wf" "$job" 1.37.0 1.22.0 && pass "1.37.0 >= 1.22.0" || fail "$(cat "${WORK_ROOT}/log")"
  floor "$wf" "$job" 1.22.0 1.22.0 && pass "equal is enough" || fail "$(cat "${WORK_ROOT}/log")"
  floor "$wf" "$job" 1.22.0 1.37.0 && fail "1.22.0 passed a 1.37.0 floor" || pass "1.22.0 < 1.37.0 refused"
  floor "$wf" "$job" 1.9.0 1.22.0 && fail "1.9.0 passed (string compare?)" || pass "1.9.0 < 1.22.0 refused (numeric compare)"
  floor "$wf" "$job" "" 1.22.0 && fail "passed without the cli installed" || pass "cli missing refused"
done

finish
