#!/usr/bin/env bash
# Every check of this repo that is not actionlint: the workflow invariants and
# the behaviour tests that run real workflow steps against temp repos.
set -euo pipefail
cd "$(dirname "$0")"
status=0
echo "== check_workflows.py"
python3 check_workflows.py || status=1
for t in ./*.test.sh; do
  [ -e "$t" ] || continue
  echo "== ${t#./}"
  bash "$t" || status=1
done
exit "$status"
