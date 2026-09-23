#!/usr/bin/env bash
# Shared helpers for the behaviour tests of the reusable workflows.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
WORKFLOWS="${REPO_ROOT}/.github/workflows"

# A test that spawns git must never inherit the caller's repository (a hook,
# a worktree): every git below works on its own temp repos.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

FAILURES=0
CURRENT_TEST=""

fail() {
  echo "  FAIL [${CURRENT_TEST}]: $*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "  ok   [${CURRENT_TEST}]: $*"
}

# extract_step <workflow file> <job> <step id|name> > script.sh
extract_step() {
  python3 "${TESTS_DIR}/extract_step.py" "${WORKFLOWS}/$1" "$2" "$3"
}

# run_step <script> — the way Actions runs a `run:` with the default shell.
run_step() {
  bash --noprofile --norc -eo pipefail "$1"
}

finish() {
  if [ "${FAILURES}" -gt 0 ]; then
    echo "${FAILURES} failure(s)" >&2
    exit 1
  fi
  echo "all passed"
}
