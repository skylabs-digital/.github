#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for the deploy rollback (DEP-04): the real "Last good
# release" and "Rollback on failure" steps of app-release.yml and
# deploy-manual.yml, with a fake `yarn` and a fake `sl` that record what they
# were asked to do and from which checkout.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rollback-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
LOG="${WORK_ROOT}/calls.log"
mkdir -p "${WORK_ROOT}/bin"

# The fake sl: records its cwd's deploy/compose.yml (which release's fragment
# it would push) and its arguments.
cat > "${WORK_ROOT}/sl.mjs" <<'JS'
import { readFileSync, appendFileSync } from "node:fs";
let fragment = "none";
try { fragment = readFileSync("deploy/compose.yml", "utf8").trim(); } catch {}
appendFileSync(process.env.FAKE_LOG, `sl ${process.argv.slice(2).join(" ")} [fragment=${fragment}]\n`);
process.exit(Number(process.env.FAKE_SL_RC || 0));
JS
cat > "${WORK_ROOT}/bin/yarn" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "bin" ] && [ "$2" = "sl" ]; then echo "${FAKE_SL_BIN}"; exit 0; fi
if [ "$1" = "sl" ] && [ "$4" = "status" ]; then printf '%s\n' "${FAKE_STATUS}"; exit 0; fi
echo "yarn $*" >> "${FAKE_LOG}"
FAKE
chmod +x "${WORK_ROOT}/bin/yarn"

# An app repo with two releases whose fragments differ, and the job's
# workspace: a shallow checkout of the NEW release, like actions/checkout.
git init -q --bare -b main "${WORK_ROOT}/origin.git"
git clone -q "${WORK_ROOT}/origin.git" "${WORK_ROOT}/seed" 2>/dev/null
(
  cd "${WORK_ROOT}/seed"
  mkdir -p deploy
  echo "fragment-of-v1.0.0" > deploy/compose.yml
  git add -A && git commit -q -m "feat: one" && git tag v1.0.0
  echo "fragment-of-v1.1.0" > deploy/compose.yml
  git commit -qam "feat: two" && git tag v1.1.0
  git push -q origin main v1.0.0 v1.1.0
)
git clone -q --depth 1 --branch v1.1.0 "file://${WORK_ROOT}/origin.git" "${WORK_ROOT}/ws" 2>/dev/null

extract_step app-release.yml deploy "Last good release (for the rollback)" > "${WORK_ROOT}/ar-last.sh"
extract_step app-release.yml deploy "Rollback on failure" > "${WORK_ROOT}/ar-rollback.sh"
extract_step deploy-manual.yml deploy "Last good release (for the rollback)" > "${WORK_ROOT}/dm-last.sh"
extract_step deploy-manual.yml deploy "Rollback on failure" > "${WORK_ROOT}/dm-rollback.sh"

status_json() {  # status_json <svc>=<lastGood> ...
  local items=() kv
  for kv in "$@"; do items+=("{\"service\":\"${kv%%=*}\",\"lastGood\":\"${kv#*=}\"}"); done
  local IFS=,
  printf '{"command":"deploy","ok":true,"exitCode":0,"data":{"app":"app","env":"qa","servicios":[%s]}}' "${items[*]}"
}

# last_good <script> <service> <tag> <status json> — prints the tag output.
last_good() {
  : > "${WORK_ROOT}/out"
  (
    cd "${WORK_ROOT}/ws"
    PATH="${WORK_ROOT}/bin:${PATH}" FAKE_LOG="$LOG" FAKE_SL_BIN="${WORK_ROOT}/sl.mjs" FAKE_STATUS="$4" \
      DEPLOY_ENV=qa SERVICE="$2" TAG="$3" GITHUB_OUTPUT="${WORK_ROOT}/out" run_step "$1"
  ) > /dev/null 2>&1 || true
  grep '^tag=' "${WORK_ROOT}/out" | cut -d= -f2-
}

# rollback <script> <service> <outcome> <last good> [sl rc] — the calls, in $LOG.
rollback() {
  : > "$LOG"
  rm -rf "${WORK_ROOT}/rt"; mkdir -p "${WORK_ROOT}/rt"
  git -C "${WORK_ROOT}/ws" worktree prune
  set +e
  (
    cd "${WORK_ROOT}/ws"
    PATH="${WORK_ROOT}/bin:${PATH}" FAKE_LOG="$LOG" FAKE_SL_RC="${5:-0}" RUNNER_TEMP="${WORK_ROOT}/rt" \
      DEPLOY_ENV=qa SERVICE="$2" DEPLOY_OUTCOME="$3" LAST_GOOD="$4" SL_BIN="${WORK_ROOT}/sl.mjs" \
      run_step "$1"
  ) > "${WORK_ROOT}/rollback.log" 2>&1
  RB_RC=$?
  set -e
}

for wf in ar dm; do
  CURRENT_TEST="${wf}: reads the last-good release before deploying"
  got="$(last_good "${WORK_ROOT}/${wf}-last.sh" "" v1.1.0 "$(status_json app-api=v1.0.0 app-web=v1.0.0)")"
  [ "$got" = "v1.0.0" ] && pass "every service on v1.0.0 → v1.0.0" || fail "got '${got}'"
  got="$(last_good "${WORK_ROOT}/${wf}-last.sh" "" v1.1.0 "$(status_json app-api=v1.0.0 app-web=v0.9.0)")"
  [ -z "$got" ] && pass "mixed last-good → nothing to restore" || fail "got '${got}' from mixed tags"
  got="$(last_good "${WORK_ROOT}/${wf}-last.sh" "" v1.1.0 "$(status_json app-api=v1.1.0)")"
  [ -z "$got" ] && pass "last-good is the tag being deployed → nothing to restore" || fail "got '${got}'"
  got="$(last_good "${WORK_ROOT}/${wf}-last.sh" "" v1.1.0 "not json")"
  [ -z "$got" ] && pass "unreadable status → nothing to restore" || fail "got '${got}'"
done
CURRENT_TEST="dm: a targeted deploy reads that service's last-good"
got="$(last_good "${WORK_ROOT}/dm-last.sh" app-web v1.1.0 "$(status_json app-api=v0.9.0 app-web=v1.0.0)")"
[ "$got" = "v1.0.0" ] && pass "app-web → v1.0.0" || fail "got '${got}'"

for wf in ar dm; do
  CURRENT_TEST="DEP-04 ${wf}: a failed deploy restores the last-good release's fragment, not only its images"
  rollback "${WORK_ROOT}/${wf}-rollback.sh" "" failure v1.0.0
  [ "$RB_RC" -eq 0 ] || fail "exit ${RB_RC}: $(cat "${WORK_ROOT}/rollback.log")"
  grep -q '^sl deploy qa --tag v1.0.0 --skip-migrate --yes \[fragment=fragment-of-v1.0.0\]$' "$LOG" \
    && pass "sl deploy --tag v1.0.0 from v1.0.0's checkout" \
    || fail "calls: $(cat "$LOG")"
  ! grep -q 'rollback' "$LOG" && pass "no images-only rollback on top" || fail "calls: $(cat "$LOG")"

  CURRENT_TEST="DEP-04 ${wf}: when the redeploy fails, falls back to the images-only rollback"
  rollback "${WORK_ROOT}/${wf}-rollback.sh" "" failure v1.0.0 1
  grep -q '^yarn sl deploy qa rollback --yes$' "$LOG" && pass "images-only fallback" || fail "calls: $(cat "$LOG")"

  CURRENT_TEST="DEP-04 ${wf}: nothing to restore → images-only rollback, as before"
  rollback "${WORK_ROOT}/${wf}-rollback.sh" "" failure ""
  [ "$(cat "$LOG")" = "yarn sl deploy qa rollback --yes" ] && pass "images only" || fail "calls: $(cat "$LOG")"

  CURRENT_TEST="DEP-04 ${wf}: a cancelled deploy gets the quick images-only rollback"
  rollback "${WORK_ROOT}/${wf}-rollback.sh" "" cancelled v1.0.0
  [ "$(cat "$LOG")" = "yarn sl deploy qa rollback --yes" ] && pass "images only" || fail "calls: $(cat "$LOG")"
done

CURRENT_TEST="DEP-04 dm: a targeted deploy restores that service only"
rollback "${WORK_ROOT}/dm-rollback.sh" app-web failure v1.0.0
grep -q '^sl deploy qa app-web --tag v1.0.0 --skip-migrate --yes \[fragment=fragment-of-v1.0.0\]$' "$LOG" \
  && pass "app-web back to v1.0.0 with its fragment" || fail "calls: $(cat "$LOG")"

finish
