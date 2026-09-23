#!/usr/bin/env bash
# `check && pass || fail` is intended: pass never fails.
# shellcheck disable=SC2015
# Behaviour tests for "Pin SSH host keys" (DEP-10): the real step, then the
# `ssh` it installs asked for its effective config (`ssh -G`, no connection)
# with the same `-o StrictHostKeyChecking=accept-new` that `sl` passes.
# shellcheck source=scripts/tests/lib.sh
source "$(dirname "$0")/lib.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/known-hosts-test.XXXXXX")"
trap 'rm -rf "${WORK_ROOT}"' EXIT

ssh-keygen -q -t ed25519 -N '' -C test -f "${WORK_ROOT}/hostkey"
LINE="10.10.10.2 $(cut -d' ' -f1,2 "${WORK_ROOT}/hostkey.pub")"

# pin <workflow> <var value> <registry file content or ""> — runs the step;
# RC and the PATH it added are left in $RC / $ADDED.
pin() {
  local wf="$1" var="$2" reg="$3"
  local ws="${WORK_ROOT}/ws" rt="${WORK_ROOT}/rt"
  rm -rf "$ws" "$rt"; mkdir -p "$ws/.infra-registry/registry" "$rt"
  if [ -n "$reg" ]; then printf '%s\n' "$reg" > "$ws/.infra-registry/registry/known_hosts"; fi
  extract_step "$wf" deploy "Pin SSH host keys" > "${WORK_ROOT}/pin.sh"
  : > "${WORK_ROOT}/path"
  set +e
  KNOWN_HOSTS_VAR="$var" REGISTRY_KNOWN_HOSTS="$ws/.infra-registry/registry/known_hosts" \
    RUNNER_TEMP="$rt" GITHUB_PATH="${WORK_ROOT}/path" run_step "${WORK_ROOT}/pin.sh" > "${WORK_ROOT}/log" 2>&1
  RC=$?
  set -e
  ADDED="$(cat "${WORK_ROOT}/path")"
}

# effective <option> — what the pinned ssh would use against 10.10.10.2 when
# called the way `sl` calls it.
effective() {
  PATH="${ADDED}:${PATH}" ssh -G -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    deploy@10.10.10.2 2>/dev/null | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }'
}

for wf in app-release.yml deploy-manual.yml; do
  CURRENT_TEST="DEP-10 ${wf}: the variable pins the host keys"
  pin "$wf" "$LINE" ""
  [ "$RC" -eq 0 ] && pass "step ok" || fail "exit ${RC}: $(cat "${WORK_ROOT}/log")"
  [ "$(effective stricthostkeychecking)" = "true" ] && pass "sl's accept-new is overridden" \
    || fail "stricthostkeychecking=$(effective stricthostkeychecking)"
  [ "$(effective userknownhostsfile)" = "${WORK_ROOT}/rt/ssh-pinned/known_hosts" ] \
    && pass "only the pinned known_hosts is read" || fail "userknownhostsfile=$(effective userknownhostsfile)"
  [ "$(effective globalknownhostsfile)" = "/dev/null" ] && pass "no global known_hosts" \
    || fail "globalknownhostsfile=$(effective globalknownhostsfile)"
  [ "$(PATH="${ADDED}:${PATH}" command -v ssh)" = "${WORK_ROOT}/rt/ssh-pinned/bin/ssh" ] \
    && pass "the bastion hop's \`ssh\` (ProxyCommand, via PATH) is the pinned one too" \
    || fail "ssh on PATH: $(PATH="${ADDED}:${PATH}" command -v ssh)"

  CURRENT_TEST="DEP-10 ${wf}: infra's registry/known_hosts wins over the variable"
  pin "$wf" "garbage that would fail" "$LINE"
  [ "$RC" -eq 0 ] && grep -q "registry/known_hosts" "${WORK_ROOT}/log" && pass "registry used" \
    || fail "exit ${RC}: $(cat "${WORK_ROOT}/log")"

  CURRENT_TEST="DEP-10 ${wf}: no source keeps today's behaviour, loudly"
  pin "$wf" "" ""
  [ "$RC" -eq 0 ] && [ -z "$ADDED" ] && pass "nothing on PATH" || fail "exit ${RC}, PATH '${ADDED}'"
  grep -q "not pinned" "${WORK_ROOT}/log" && pass "warns" || fail "log: $(cat "${WORK_ROOT}/log")"

  CURRENT_TEST="DEP-10 ${wf}: a variable with no valid line stops the deploy"
  pin "$wf" "not a known_hosts line" ""
  [ "$RC" -ne 0 ] && [ -z "$ADDED" ] && pass "refused" || fail "exit ${RC}, PATH '${ADDED}'"
done

finish
