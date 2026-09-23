#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for security.yml's gates: fail-closed scanners on a push
# (DEP-18(3)) and a Gitleaks config that must extend the default rules
# (SEC-21(2)). The real steps, with fake inputs.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/security-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
extract_step security.yml osv-scan gate > "${WORK_ROOT}/osv.sh"
extract_step security.yml docker-scan "Gate on fixable findings" > "${WORK_ROOT}/grype.sh"
extract_step security.yml secrets-scan "Scan repository (full history)" > "${WORK_ROOT}/gitleaks.sh"

# gate <script> <event> [results file content] — exit code; env passes through.
gate() {
  local dir="${WORK_ROOT}/g"; rm -rf "$dir"; mkdir -p "$dir/rt"
  if [ $# -ge 3 ]; then printf '%s' "$3" > "$dir/osv-results.json"; cp "$dir/osv-results.json" "$dir/grype-results.json"; fi
  set +e
  (cd "$dir" && EVENT="$2" GATE_MODE=auto FAIL_ON=critical IMAGE=app-api RUNNER_TEMP="$dir/rt" \
    GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_OUTPUT="$dir/out" run_step "$1") > "${WORK_ROOT}/log" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

CURRENT_TEST="DEP-18: OSV without a result is red on push, a warning on PR"
OSV_OUTCOME=failure gate "${WORK_ROOT}/osv.sh" push && fail "push: green without a scan" || pass "push: red"
OSV_OUTCOME=failure gate "${WORK_ROOT}/osv.sh" pull_request && pass "PR: warning only" || fail "PR: $(cat "${WORK_ROOT}/log")"
OSV_OUTCOME=failure gate "${WORK_ROOT}/osv.sh" push "{not json" && fail "push: green on garbage" || pass "push: unparsable is red"
OSV_OUTCOME=success gate "${WORK_ROOT}/osv.sh" push && pass "push: a clean scan stays green" || fail "$(cat "${WORK_ROOT}/log")"
OSV_OUTCOME=success gate "${WORK_ROOT}/osv.sh" push '{"results":[]}' && pass "push: empty results stay green" || fail "$(cat "${WORK_ROOT}/log")"

CURRENT_TEST="DEP-18: Grype that could not scan is red on push, a warning on schedule"
GRYPE_RC=1 gate "${WORK_ROOT}/grype.sh" push '' && fail "push: green without a scan" || pass "push: red"
GRYPE_RC=1 gate "${WORK_ROOT}/grype.sh" schedule '' && pass "schedule: warning only" || fail "$(cat "${WORK_ROOT}/log")"
GRYPE_RC=0 gate "${WORK_ROOT}/grype.sh" push '{"matches":[]}' && pass "push: a clean scan stays green" || fail "$(cat "${WORK_ROOT}/log")"

CURRENT_TEST="SEC-21: a .gitleaks.toml must extend the default rules"
mkdir -p "${WORK_ROOT}/bin"
printf '#!/bin/sh\necho "gitleaks $*" >> "%s/gitleaks.log"\n' "${WORK_ROOT}" > "${WORK_ROOT}/bin/gitleaks"
chmod +x "${WORK_ROOT}/bin/gitleaks"
leaks() {  # leaks <config content or "none"> — exit code
  local dir="${WORK_ROOT}/repo"; rm -rf "$dir"; mkdir -p "$dir"
  if [ "$1" != "none" ]; then printf '%s\n' "$1" > "$dir/.gitleaks.toml"; fi
  set +e
  (cd "$dir" && PATH="${WORK_ROOT}/bin:${PATH}" run_step "${WORK_ROOT}/gitleaks.sh") > "${WORK_ROOT}/log" 2>&1
  local rc=$?
  set -e
  return "$rc"
}
leaks '[allowlist]
paths = ["docs/"]' && fail "allowlist-only config accepted (zero rules)" || pass "allowlist-only config refused"
leaks '[extend]
useDefault = true

[allowlist]
paths = ["docs/"]' && pass "extending config accepted" || fail "$(cat "${WORK_ROOT}/log")"
leaks none && pass "no config: defaults" || fail "$(cat "${WORK_ROOT}/log")"

finish
