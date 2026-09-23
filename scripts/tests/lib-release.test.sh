#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for lib-release.yml's `Semantic release` step: the real
# script, with a fake `yarn` whose `dlx semantic-release` fails the way a
# rejected push does.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lib-release-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
SCRIPT="${WORK_ROOT}/release.sh"
extract_step lib-release.yml release "Semantic release" > "${SCRIPT}"

mkdir -p "${WORK_ROOT}/bin"
cat > "${WORK_ROOT}/bin/yarn" <<'FAKE'
#!/usr/bin/env bash
echo "yarn $*" >> "${FAKE_YARN_LOG}"
case "$1" in
  dlx) exit "$(cat "${FAKE_DLX_RC}")" ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${WORK_ROOT}/bin/yarn"

setup() {
  local dir="$1"
  git init -q --bare -b main "${dir}/origin.git"
  git clone -q "${dir}/origin.git" "${dir}/seed" 2>/dev/null
  (cd "${dir}/seed" && echo 1 > f && git add f && git commit -q -m "fix: a" && git push -q origin main)
  git clone -q "${dir}/origin.git" "${dir}/work" 2>/dev/null
}

push_other() {
  (cd "$1/seed" && echo "$2" >> f && git commit -qam "$2" && git push -q origin main)
}

run_release() {
  local dir="$1"
  : > "${dir}/yarn.log"
  echo 1 > "${dir}/dlx_rc"
  set +e
  (
    cd "${dir}/work"
    PATH="${WORK_ROOT}/bin:${PATH}" FAKE_YARN_LOG="${dir}/yarn.log" FAKE_DLX_RC="${dir}/dlx_rc" \
      GITHUB_SHA="$(git rev-parse HEAD)" run_step "${SCRIPT}"
  ) > "${dir}/log" 2>&1
  RC=$?
  set -e
}

CURRENT_TEST="DEP-03: a lib release does not publish commits it did not validate"
d="${WORK_ROOT}/t1"; mkdir -p "$d"; setup "$d"
push_other "$d" "feat: merged meanwhile"
run_release "$d"
[ "$RC" -eq 0 ] && pass "exits 0" || fail "exit ${RC}: $(cat "$d/log")"
[ "$(grep -c 'dlx' "$d/yarn.log")" -eq 1 ] && pass "semantic-release ran once, no retry on the newer main" \
  || fail "retried on a main it did not validate: $(cat "$d/yarn.log")"
grep -q "superseded" "$d/log" && pass "says it was superseded" || fail "log: $(cat "$d/log")"

CURRENT_TEST="DEP-03: main moved only by [skip ci] commits: the lib release retries"
d="${WORK_ROOT}/t2"; mkdir -p "$d"; setup "$d"
push_other "$d" "chore(release): 1.2.3 [skip ci]"
run_release "$d"
[ "$(grep -c 'dlx' "$d/yarn.log")" -ge 2 ] && pass "retried after a [skip ci] move" || fail "yarn calls: $(cat "$d/yarn.log")"

CURRENT_TEST="a real failure on an unmoved main is still an error"
d="${WORK_ROOT}/t3"; mkdir -p "$d"; setup "$d"
run_release "$d"
[ "$RC" -ne 0 ] && pass "exit ${RC}" || fail "exited 0 on a real failure"

finish
