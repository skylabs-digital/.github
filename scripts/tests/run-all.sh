#!/usr/bin/env bash
# Every check of this repo that is not actionlint: the workflow invariants and
# the behaviour tests that run real workflow steps against temp repos.
set -euo pipefail
cd "$(dirname "$0")"
# The steps under test use these, as the runners do: a missing one is a red
# that names the tool, not a confusing failure deep inside a test.
for tool in git node jq python3 ssh ssh-keygen sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done
status=0
echo "== check_workflows.py"
python3 check_workflows.py || status=1
for t in ./*.test.sh; do
  [ -e "$t" ] || continue
  echo "== ${t#./}"
  bash "$t" || status=1
done
exit "$status"
