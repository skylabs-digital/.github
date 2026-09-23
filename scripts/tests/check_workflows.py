#!/usr/bin/env python3
"""Invariants of the reusable workflows that actionlint does not know about.

Each check is a function that returns a list of error strings. A new rule
comes with the commit that makes it true, so `git log -p` on this file is the
list of what the fleet decided never to regress on.

Run it from anywhere: `python3 scripts/tests/check_workflows.py`.
"""
from __future__ import annotations

import glob
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW_DIR = os.path.join(ROOT, ".github", "workflows")

SHA_PIN = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
# Our own reusables are consumed at @main on purpose (DEP-16(2) is Fer's call);
# they are the only `uses:` allowed without a SHA.
OWN_REUSABLE = re.compile(r"^skylabs-digital/\.github/\.github/workflows/[\w.-]+\.ya?ml@main$")


def load_all() -> dict[str, dict]:
    """Every workflow, parsed. A file that does not parse is itself an error."""
    out: dict[str, dict] = {}
    for path in sorted(glob.glob(os.path.join(WORKFLOW_DIR, "*.yml"))):
        with open(path, encoding="utf-8") as f:
            out[os.path.basename(path)] = yaml.safe_load(f)
    return out


def raw_lines(name: str) -> list[str]:
    with open(os.path.join(WORKFLOW_DIR, name), encoding="utf-8") as f:
        return f.read().splitlines()


def jobs(wf: dict) -> dict[str, dict]:
    return wf.get("jobs") or {}


def steps(job: dict) -> list[dict]:
    return job.get("steps") or []


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------


def check_parses(wfs: dict[str, dict]) -> list[str]:
    errors = []
    for name, wf in wfs.items():
        if not isinstance(wf, dict) or "jobs" not in wf:
            errors.append(f"{name}: does not parse to a workflow with jobs")
    return errors


def check_actions_pinned_by_sha(wfs: dict[str, dict]) -> list[str]:
    """Third-party actions by full SHA, with the tag as a comment on the line."""
    errors = []
    for name, wf in wfs.items():
        lines = raw_lines(name)
        for job_id, job in jobs(wf).items():
            refs = [job["uses"]] if "uses" in job else []
            refs += [s["uses"] for s in steps(job) if "uses" in s]
            for ref in refs:
                if ref.startswith("./") or OWN_REUSABLE.match(ref):
                    continue
                if not SHA_PIN.match(ref):
                    errors.append(f"{name}:{job_id}: `{ref}` is not pinned by a full SHA")
                    continue
                if not any(ref in l and re.search(r"#\s*v\d", l) for l in lines):
                    errors.append(f"{name}:{job_id}: `{ref}` has no `# vX.Y.Z` comment")
    return errors


CHECKS = [
    check_parses,
    check_actions_pinned_by_sha,
]


def main() -> int:
    wfs = load_all()
    failed = 0
    for check in CHECKS:
        errors = check(wfs)
        label = check.__name__.removeprefix("check_")
        if errors:
            failed += 1
            print(f"FAIL {label}")
            for e in errors:
                print(f"  - {e}")
        else:
            print(f"ok   {label}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
