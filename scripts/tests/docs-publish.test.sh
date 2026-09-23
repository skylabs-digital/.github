#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for docs-publish.yml (DEP-19): which `sl` the job runs, and
# that a docs failure is visible.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/docs-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
mkdir -p "${WORK_ROOT}/bin"
cat > "${WORK_ROOT}/bin/npm" <<'FAKE'
#!/usr/bin/env bash
echo "npm $*" >> "${FAKE_LOG}"
FAKE
chmod +x "${WORK_ROOT}/bin/npm"
extract_step docs-publish.yml publish "Resolve sl (the repo's pin, else cli-version, else 1.37.0)" > "${WORK_ROOT}/resolve.sh"

# resolve <pinned version or ""> <cli-version input> — leaves the log in $LOG_OUT.
resolve() {
  local app="${WORK_ROOT}/app" rt="${WORK_ROOT}/rt"
  rm -rf "$app" "$rt"; mkdir -p "$app" "$rt"
  if [ -n "$1" ]; then
    mkdir -p "$app/node_modules/@skylabs-digital/cli"
    printf '{ "version": "%s" }\n' "$1" > "$app/node_modules/@skylabs-digital/cli/package.json"
  fi
  : > "${WORK_ROOT}/npm.log"
  (cd "$app" && PATH="${WORK_ROOT}/bin:${PATH}" FAKE_LOG="${WORK_ROOT}/npm.log" RUNNER_TEMP="$rt" \
    GITHUB_PATH="${WORK_ROOT}/path" CLI_VERSION="$2" MIN_VERSION=1.21.0 FALLBACK_VERSION=1.37.0 \
    run_step "${WORK_ROOT}/resolve.sh") > "${WORK_ROOT}/log" 2>&1
  LOG_OUT="$(cat "${WORK_ROOT}/log") $(cat "${WORK_ROOT}/npm.log")"
}

CURRENT_TEST="DEP-19: the repo's own pin reads its own descriptor"
resolve 1.34.1 ""
case "$LOG_OUT" in *"this repo's pin, 1.34.1"*) pass "uses 1.34.1 (resuelto's pin)" ;; *) fail "$LOG_OUT" ;; esac
grep -q 'exec yarn sl' "${WORK_ROOT}/rt/sl-bin/sl" && pass "sl is yarn sl" || fail "shim: $(cat "${WORK_ROOT}/rt/sl-bin/sl")"

CURRENT_TEST="DEP-19: no pin → 1.37.0, not 1.21.0"
resolve "" ""
case "$LOG_OUT" in *"@skylabs-digital/cli@1.37.0"*) pass "installs 1.37.0" ;; *) fail "$LOG_OUT" ;; esac

CURRENT_TEST="DEP-19: a pin older than auth: github → fallback"
resolve 1.12.0 ""
case "$LOG_OUT" in *"@skylabs-digital/cli@1.37.0"*) pass "1.12.0 pinned → installs 1.37.0" ;; *) fail "$LOG_OUT" ;; esac

CURRENT_TEST="DEP-19: an explicit cli-version still wins"
resolve 1.34.1 1.24.0
case "$LOG_OUT" in *"@skylabs-digital/cli@1.24.0"*) pass "installs 1.24.0" ;; *) fail "$LOG_OUT" ;; esac

CURRENT_TEST="DEP-19: a docs failure is red, not continue-on-error"
python3 - "${WORKFLOWS}/docs-publish.yml" <<'PY' && pass "the publish job can fail the run" || fail "publish is continue-on-error"
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["publish"]
sys.exit(1 if job.get("continue-on-error") else 0)
PY

finish
