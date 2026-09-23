#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for deploy-manual.yml's gate: the real step, run with the
# env Actions would give it.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
SCRIPT="${WORK_ROOT}/guard.sh"
extract_step deploy-manual.yml guard "Validar entorno y confirmación" > "${SCRIPT}"

# gate <env> <tag> <confirm> <github ref> — exit code of the gate.
gate() {
  set +e
  DEPLOY_ENV="$1" TAG="$2" CONFIRM="$3" GITHUB_REF="$4" SERVICE="" \
    DEFAULT_BRANCH=main GITHUB_ACTOR=tester GITHUB_STEP_SUMMARY="${WORK_ROOT}/summary" \
    run_step "${SCRIPT}" > "${WORK_ROOT}/log" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

CURRENT_TEST="DEP-09: only a vX.Y.Z release can be deployed"
gate qa v1.2.3 "" refs/heads/main && pass "v1.2.3 from main" || fail "v1.2.3 refused: $(cat "${WORK_ROOT}/log")"
for bad in latest qa-stable 27338f1c0ffee v1.2 "v1.2.3; rm -rf /"; do
  gate qa "$bad" "" refs/heads/main && fail "accepted tag '${bad}'" || pass "refuses '${bad}'"
done

CURRENT_TEST="SEC-01: dispatched only from the default branch or a v* tag"
gate qa v1.2.3 "" refs/tags/v1.2.3 && pass "from a tag" || fail "tag refused: $(cat "${WORK_ROOT}/log")"
gate qa v1.2.3 "" refs/heads/feature/x && fail "accepted a dispatch from a feature branch" || pass "refuses a feature branch"

CURRENT_TEST="prod still needs the typed confirmation"
gate prod v1.2.3 "" refs/heads/main && fail "prod without confirm" || pass "prod without confirm refused"
gate prod v1.2.3 prod refs/heads/main && pass "prod with confirm" || fail "prod with confirm refused: $(cat "${WORK_ROOT}/log")"
gate staging v1.2.3 "" refs/heads/main && fail "accepted env staging" || pass "unknown env refused"

finish
