#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour test for the CaC jobs' first step (CAC-19): an age key in the
# environment stops the job before anything runs.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cac-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
mkdir -p "${WORK_ROOT}/app/cac" && touch "${WORK_ROOT}/app/cac/stack.ts"

for job in cac-plan cac-apply; do
  CURRENT_TEST="CAC-19 ${job}"
  extract_step app-release.yml "$job" stack > "${WORK_ROOT}/s.sh"
  : > "${WORK_ROOT}/out"
  set +e
  (cd "${WORK_ROOT}/app" && SOPS_AGE_KEY=AGE-SECRET-KEY-TEST IDACHU_CAC_KEY=k GITHUB_OUTPUT="${WORK_ROOT}/out" \
    run_step "${WORK_ROOT}/s.sh") > /dev/null 2>&1
  rc=$?
  (cd "${WORK_ROOT}/app" && IDACHU_CAC_KEY=k GITHUB_OUTPUT="${WORK_ROOT}/out" run_step "${WORK_ROOT}/s.sh") > /dev/null 2>&1
  rc2=$?
  set -e
  [ "$rc" -ne 0 ] && pass "an age key in the env stops the job" || fail "ran with SOPS_AGE_KEY set"
  [ "$rc2" -eq 0 ] && grep -q 'present=true' "${WORK_ROOT}/out" && pass "without it, runs as before" || fail "rc=${rc2} out=$(cat "${WORK_ROOT}/out")"
done

finish
