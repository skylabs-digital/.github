#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for app-release.yml's `version` job: the bump step runs for
# real against a throwaway bare "origin".
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bumper-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
SCRIPT="${WORK_ROOT}/bump.sh"
extract_step app-release.yml version bump > "${SCRIPT}"

# new_origin <dir> — a bare origin with v1.0.0 released. Prints nothing.
new_origin() {
  local dir="$1"
  git init -q --bare -b main "${dir}/origin.git"
  git clone -q "${dir}/origin.git" "${dir}/seed" 2>/dev/null
  (
    cd "${dir}/seed"
    echo '{ "name": "app", "version": "1.0.0" }' > package.json
    printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n- first\n' > CHANGELOG.md
    git add -A && git commit -q -m "chore: init"
    git tag -a v1.0.0 -m "Release v1.0.0"
    git push -q origin main v1.0.0
  )
}

# commit_on_origin <dir> <message> — someone else merges to main. Prints the sha.
commit_on_origin() {
  local dir="$1" msg="$2"
  (
    cd "${dir}/seed"
    git pull -q --rebase origin main
    echo "$msg" >> notes.txt
    git add -A && git commit -q -m "$msg"
    git push -q origin main
    git rev-parse HEAD
  )
}

# run_bump <dir> <sha> — checks out <sha> the way actions/checkout does for a
# push event and runs the step with GITHUB_SHA=<sha>. Exit code in $BUMP_RC.
run_bump() {
  local dir="$1" sha="$2"
  rm -rf "${dir}/work"
  git clone -q "${dir}/origin.git" "${dir}/work" 2>/dev/null
  (
    cd "${dir}/work"
    git checkout -q -B main "${sha}"
    git config user.name "semantic-release-bot-skylabs[bot]"
    git config user.email "bot@example.invalid"
  )
  : > "${dir}/output"
  : > "${dir}/summary"
  set +e
  (
    cd "${dir}/work"
    GITHUB_SHA="${sha}" GITHUB_OUTPUT="${dir}/output" GITHUB_STEP_SUMMARY="${dir}/summary" \
      run_step "${SCRIPT}"
  ) > "${dir}/log" 2>&1
  BUMP_RC=$?
  set -e
}

output_of() { grep "^$2=" "$1/output" | tail -n1 | cut -d= -f2-; }
origin_main() { git --git-dir="$1/origin.git" rev-parse main; }
origin_tags() { git --git-dir="$1/origin.git" tag -l | sort | tr '\n' ' '; }

# ---------------------------------------------------------------------------
CURRENT_TEST="releases the validated commit when main did not move"
d="${WORK_ROOT}/t1"; mkdir -p "$d"; new_origin "$d"
A="$(commit_on_origin "$d" "fix: a")"
run_bump "$d" "$A"
if [ "$BUMP_RC" -ne 0 ]; then fail "exit ${BUMP_RC}: $(cat "$d/log")"; fi
[ "$(output_of "$d" bumped)" = "true" ] && pass "bumped=true" || fail "bumped=$(output_of "$d" bumped)"
[ "$(output_of "$d" version)" = "1.0.1" ] && pass "version 1.0.1" || fail "version=$(output_of "$d" version)"
parent="$(git --git-dir="$d/origin.git" rev-parse 'v1.0.1^{commit}^')"
[ "$parent" = "$A" ] && pass "the release commit sits on the validated sha" || fail "release parent is ${parent}, not ${A}"

# ---------------------------------------------------------------------------
CURRENT_TEST="DEP-03: does not publish commits this run did not validate"
d="${WORK_ROOT}/t2"; mkdir -p "$d"; new_origin "$d"
A="$(commit_on_origin "$d" "fix: a")"
B="$(commit_on_origin "$d" "feat: b, merged while the run for a waited")"
run_bump "$d" "$A"
[ "$BUMP_RC" -eq 0 ] && pass "exits 0 (superseded is not a failure)" || fail "exit ${BUMP_RC}: $(cat "$d/log")"
[ "$(output_of "$d" bumped)" = "false" ] && pass "bumped=false" || fail "bumped=$(output_of "$d" bumped) — it released B, which it never validated"
[ "$(origin_main "$d")" = "$B" ] && pass "origin main untouched" || fail "origin main moved to $(origin_main "$d")"
[ "$(origin_tags "$d")" = "v1.0.0 " ] && pass "no new tag" || fail "tags on origin: $(origin_tags "$d")"
grep -q "newer run" "$d/summary" && pass "the summary says the newer run releases it" || fail "summary: $(cat "$d/summary")"

# ---------------------------------------------------------------------------
CURRENT_TEST="DEP-03: main moved only by [skip ci] commits still releases"
d="${WORK_ROOT}/t3"; mkdir -p "$d"; new_origin "$d"
A="$(commit_on_origin "$d" "fix: a")"
S="$(commit_on_origin "$d" "chore(secrets): recipients del registro [skip ci]")"
run_bump "$d" "$A"
[ "$BUMP_RC" -eq 0 ] || fail "exit ${BUMP_RC}: $(cat "$d/log")"
[ "$(output_of "$d" bumped)" = "true" ] && pass "bumped=true: no newer run exists for a [skip ci] commit" || fail "bumped=$(output_of "$d" bumped): the release would be lost"
parent="$(git --git-dir="$d/origin.git" rev-parse 'v1.0.1^{commit}^' 2>/dev/null || true)"
[ "$parent" = "$S" ] && pass "released on top of the [skip ci] commit" || fail "release parent ${parent}, expected ${S}"

# ---------------------------------------------------------------------------
CURRENT_TEST="DEP-20: a subject with a backslash does not truncate the CHANGELOG"
d="${WORK_ROOT}/t4"; mkdir -p "$d"; new_origin "$d"
A="$(commit_on_origin "$d" 'fix: handle C:\config paths and trailing text')"
run_bump "$d" "$A"
[ "$BUMP_RC" -eq 0 ] || fail "exit ${BUMP_RC}: $(cat "$d/log")"
changelog="$(git --git-dir="$d/origin.git" show v1.0.1:CHANGELOG.md)"
case "$changelog" in
  *'C:\config paths and trailing text'*) pass "the subject survives verbatim" ;;
  *) fail "CHANGELOG lost the subject: ${changelog}" ;;
esac
case "$changelog" in
  *'## [1.0.0] - 2026-01-01'*) pass "the previous entries survive" ;;
  *) fail "CHANGELOG lost the history: ${changelog}" ;;
esac


finish
