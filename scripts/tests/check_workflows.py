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


def check_pin_comments_agree(wfs: dict[str, dict]) -> list[str]:
    """One SHA, one tag. `de0fac2…  # v6.0.2` here and `# v4.3.0` there means
    one of the two comments lies, and the next person bumps the wrong one."""
    seen: dict[str, tuple[str, str]] = {}
    errors = []
    for name in wfs:
        for n, line in enumerate(raw_lines(name), 1):
            m = re.search(r"uses:\s*([^@\s]+)@([0-9a-f]{40})\s*#\s*(v[\w.-]+)", line)
            if not m:
                continue
            key = f"{m.group(1)}@{m.group(2)}"
            where = f"{name}:{n}"
            if key in seen and seen[key][0] != m.group(3):
                errors.append(
                    f"{where}: {m.group(1)} {m.group(2)[:7]} is `{m.group(3)}` here "
                    f"but `{seen[key][0]}` at {seen[key][1]}"
                )
            seen.setdefault(key, (m.group(3), where))
    return errors


def run_scripts(wfs: dict[str, dict]):
    """(workflow, job, step name, run text) for every `run:` step."""
    for name, wf in wfs.items():
        for job_id, job in jobs(wf).items():
            for s in steps(job):
                if "run" in s:
                    yield name, job_id, s.get("name") or s.get("id") or s["run"][:30], s["run"]


def check_no_unverified_installs(wfs: dict[str, dict]) -> list[str]:
    """No `curl | sh`, no `sudo` and no unpinned `yarn dlx`: every binary a job
    runs is pinned, checksummed and lives in the job's own $RUNNER_TEMP. The
    runners are persistent hosts (DEP-02): /usr/local/bin outlives the job."""
    errors = []
    for name, job_id, step, run in run_scripts(wfs):
        for line in run.splitlines():
            code = line.split("#", 1)[0]
            if re.search(r"\|\s*(sh|bash)\b", code):
                errors.append(f"{name}:{job_id}:{step}: pipes a download into a shell")
            if re.search(r"(^|[;&|\s])sudo\s", code):
                errors.append(f"{name}:{job_id}:{step}: uses sudo")
            m = re.search(r"yarn dlx ([^\s;]+)", code)
            if m and not re.search(r"@\d+\.\d+\.\d+$", m.group(1)):
                errors.append(f"{name}:{job_id}:{step}: `yarn dlx {m.group(1)}` has no exact version")
    return errors


def check_sops_is_verified_every_time(wfs: dict[str, dict]) -> list[str]:
    """The sops that runs next to SOPS_AGE_KEY is downloaded into this job's
    $RUNNER_TEMP and checksummed unconditionally. A copy cached in $HOME was
    reused unverified whenever it existed (SEC-03, DEP-09(2), DEP-02(3))."""
    errors = []
    for name, job_id, step, run in run_scripts(wfs):
        if "getsops/sops" not in run:
            continue
        where = f"{name}:{job_id}:{step}"
        if "sha256sum -c" not in run:
            errors.append(f"{where}: installs sops without a checksum")
        if "$HOME" in run or ".local/bin" in run:
            errors.append(f"{where}: installs sops into $HOME, which outlives the job")
        if "RUNNER_TEMP" not in run:
            errors.append(f"{where}: sops does not go to $RUNNER_TEMP")
        if re.search(r"if \[ ! -[xf]", run):
            errors.append(f"{where}: the checksum sits behind an 'is it cached?' test")
    return errors


def check_deploy_manual_deploys_the_tag(wfs: dict[str, dict]) -> list[str]:
    """The fragment, descriptor and secrets pushed to the droplet are the
    tag's, not the dispatch branch's (DEP-09(1))."""
    job = jobs(wfs["deploy-manual.yml"]).get("deploy", {})
    own = [s for s in steps(job) if str(s.get("uses", "")).startswith("actions/checkout@")
           and "repository" not in (s.get("with") or {})]
    if not own:
        return ["deploy-manual.yml:deploy: no checkout of the app repo"]
    ref = (own[0].get("with") or {}).get("ref")
    if ref != "${{ inputs.tag }}":
        return [f"deploy-manual.yml:deploy: the app checkout has ref {ref!r}, not the tag"]
    return []


CHECKS = [
    check_parses,
    check_actions_pinned_by_sha,
    check_pin_comments_agree,
    check_no_unverified_installs,
    check_sops_is_verified_every_time,
    check_deploy_manual_deploys_the_tag,
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
