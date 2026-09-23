#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for the sops install step of every job that holds
# SOPS_AGE_KEY: a tampered download must stop the job and never reach PATH.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sops-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT
mkdir -p "${WORK_ROOT}/bin"
# A curl that "downloads" something that is not sops: it writes to -o.
cat > "${WORK_ROOT}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
printf 'not sops\n' > "$out"
FAKE
chmod +x "${WORK_ROOT}/bin/curl"

for spec in "app-release.yml deploy" "app-release.yml secrets-rotate" "deploy-manual.yml deploy"; do
  read -r wf job <<< "$spec"
  CURRENT_TEST="${wf}:${job}: a tampered sops never reaches PATH"
  script="${WORK_ROOT}/${wf}-${job}.sh"
  extract_step "$wf" "$job" "Install sops (pinned + checksum)" > "$script"
  rt="${WORK_ROOT}/rt-${job}"; mkdir -p "$rt"
  : > "${WORK_ROOT}/path"
  set +e
  PATH="${WORK_ROOT}/bin:${PATH}" RUNNER_TEMP="$rt" GITHUB_PATH="${WORK_ROOT}/path" \
    HOME="${WORK_ROOT}/home" run_step "$script" > "${WORK_ROOT}/log" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && pass "the job stops" || fail "exit 0 with a tampered binary"
  [ ! -s "${WORK_ROOT}/path" ] && pass "nothing added to PATH" || fail "PATH got: $(cat "${WORK_ROOT}/path")"
  [ ! -e "${WORK_ROOT}/home" ] && pass "nothing written under HOME" || fail "wrote into HOME: $(find "${WORK_ROOT}/home")"
done

finish
