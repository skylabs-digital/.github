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


def check_rollback_only_when_the_deploy_failed(wfs: dict[str, dict]) -> list[str]:
    """A rollback recreates every service. It runs when `sl deploy` itself
    failed or was cancelled, never because a later step (the `<env>-stable`
    retag, a GHCR hiccup) failed after a good deploy (DEP-05(2)); and a
    cancelled deploy is rolled back too (DEP-13(2))."""
    errors = []
    for name in ("app-release.yml", "deploy-manual.yml"):
        for job_id, job in jobs(wfs[name]).items():
            ids = {s.get("id") for s in steps(job) if "sl deploy" in str(s.get("run", ""))
                   and "rollback" not in str(s.get("run", ""))}
            ids.discard(None)
            for s in steps(job):
                if not str(s.get("name", "")).lower().startswith("rollback"):
                    continue
                cond = str(s.get("if", ""))
                where = f"{name}:{job_id}:{s.get('name')}"
                if not any(f"steps.{i}.outcome" in cond for i in ids):
                    errors.append(f"{where}: does not ask whether the sl deploy step itself failed")
                if "cancelled()" not in cond:
                    errors.append(f"{where}: a cancelled deploy is not rolled back")
    return errors


def check_stable_retag_cannot_fail_a_deploy(wfs: dict[str, dict]) -> list[str]:
    """Retagging `<env>-stable` is bookkeeping: it must not turn a good deploy
    red, nor trigger its rollback (DEP-05(3))."""
    errors = []
    for job_id, job in jobs(wfs["app-release.yml"]).items():
        for s in steps(job):
            n = str(s.get("name", ""))
            if (n.startswith("Tag as") or n == "Log in to GHCR") and job_id == "deploy":
                if s.get("continue-on-error") is not True:
                    errors.append(f"app-release.yml:{job_id}:{n}: can fail the deploy job")
    return errors


def check_latest_is_validated(wfs: dict[str, dict]) -> list[str]:
    """`:latest` is what a deploy validated, not the newest build: the build
    only pushes it when the pipeline does not deploy (DEP-17(1))."""
    job = jobs(wfs["app-release.yml"])["build-images"]
    for s in steps(job):
        tags = str((s.get("with") or {}).get("tags", ""))
        for line in tags.splitlines():
            if ":latest" in line and "!inputs.deploy" not in line:
                return [f"app-release.yml:build-images pushes :latest unconditionally: {line.strip()}"]
    return []


def check_one_deploy_at_a_time_per_app_and_env(wfs: dict[str, dict]) -> list[str]:
    """The release deploy and the manual deploy of the same app and env share
    one concurrency group: the droplet-side lock lasts one command, not one
    deploy (DEP-14(3))."""
    want = {
        ("app-release.yml", "deploy"): "deploy-${{ github.repository }}-${{ inputs.deploy-env }}",
        ("deploy-manual.yml", "deploy"): "deploy-${{ github.repository }}-${{ inputs.environment }}",
    }
    errors = []
    for (name, job_id), group in want.items():
        conc = jobs(wfs[name])[job_id].get("concurrency") or {}
        if not isinstance(conc, dict) or conc.get("group") != group:
            errors.append(f"{name}:{job_id}: concurrency group is {conc!r}, want {group!r}")
        elif conc.get("cancel-in-progress") is not False:
            errors.append(f"{name}:{job_id}: a running deploy could be cancelled mid-flight")
    return errors


# Jobs that may inherit the caller's permissions, and why.
INHERITS_ON_PURPOSE = {
    # A `uses:` job capped here would cap security.yml's weekly issue upsert,
    # which needs the caller's `issues: write` (not every caller grants it).
    ("app-release.yml", "security"),
    ("lib-release.yml", "security"),
    ("docs.yml", "docs"),
    # Needs `issues: write` from the callers that grant it; declaring it would
    # fail at startup in the callers that do not.
    ("security.yml", "weekly-security-report"),
}
# App tokens that keep the App's full permission set, and why.
APP_TOKEN_FULL_ON_PURPOSE = {
    # semantic-release's GitHub plugin comments on the released issues/PRs
    # with this token; narrowing it could fail a release. Scoped to the repo.
    ("lib-release.yml", "release"),
    # Callers do not pass app-id today (app-release forwards only npm-token).
    ("security.yml", "docker-scan"),
}


def check_every_job_declares_permissions(wfs: dict[str, dict]) -> list[str]:
    """Least privilege per job (DEP-15(1)): a job that runs PR code gets
    `contents: read`, not the caller's `contents: write, packages: write,
    id-token: write`. Only ever a SUBSET of what every caller grants: more
    fails the whole run at startup."""
    errors = []
    for name, wf in wfs.items():
        if name == "ci.yml":
            continue  # this repo's own CI: workflow-level `contents: read`
        for job_id, job in jobs(wf).items():
            if (name, job_id) in INHERITS_ON_PURPOSE:
                continue
            if "permissions" not in job:
                errors.append(f"{name}:{job_id}: no job-level permissions (inherits the caller's)")
    return errors


def check_app_tokens_are_narrow(wfs: dict[str, dict]) -> list[str]:
    """Every GitHub App token names the permissions it needs (SEC-02): the
    registry-reading one in a PR job was a contents:write token on infra,
    whose App bypasses infra's rulesets."""
    errors = []
    for name, wf in wfs.items():
        for job_id, job in jobs(wf).items():
            for s in steps(job):
                if not str(s.get("uses", "")).startswith("actions/create-github-app-token@"):
                    continue
                if (name, job_id) in APP_TOKEN_FULL_ON_PURPOSE:
                    continue
                w = s.get("with") or {}
                perms = {k: v for k, v in w.items() if k.startswith("permission-")}
                if not perms:
                    errors.append(f"{name}:{job_id}:{s.get('name')}: App token with every permission of the App")
                if w.get("repositories") == "infra" and perms != {"permission-contents": "read"}:
                    errors.append(f"{name}:{job_id}:{s.get('name')}: the registry token must be contents:read only, got {perms}")
    return errors


def check_untrusted_checkouts_keep_no_token(wfs: dict[str, dict]) -> list[str]:
    """`persist-credentials: false` on the registry checkouts and on the app
    checkouts of jobs that run PR code (SEC-02(2), DEP-15(2)): otherwise the
    token sits in .git/config for any script that runs next."""
    pr_jobs = {("app-release.yml", j) for j in ("matrix", "static-checks", "cac-plan")}
    pr_jobs |= {("lib-release.yml", j) for j in ("ci", "mutation")}
    pr_jobs |= {("security.yml", j) for j in ("osv-scan", "secrets-scan", "docker-scan")}
    errors = []
    for name, wf in wfs.items():
        for job_id, job in jobs(wf).items():
            for s in steps(job):
                if not str(s.get("uses", "")).startswith("actions/checkout@"):
                    continue
                w = s.get("with") or {}
                registry = "infra" in str(w.get("repository", ""))
                if (registry or (name, job_id) in pr_jobs) and w.get("persist-credentials") is not False:
                    what = "registry" if registry else "app"
                    errors.append(f"{name}:{job_id}: the {what} checkout persists its token")
    return errors


# Where the deploy keys may appear. Anything else reading them is a new place
# that can decrypt prod or reach a droplet, and must be a decision.
KEY_HOLDERS = {
    "SOPS_AGE_KEY": {
        ("app-release.yml", "deploy"),
        ("app-release.yml", "secrets-rotate"),
        ("deploy-manual.yml", "deploy"),
    },
    "DEPLOY_SSH_KEY": {
        ("app-release.yml", "deploy"),
        ("deploy-manual.yml", "deploy"),
    },
}
# Holders that run without a GitHub Environment, and why.
NO_ENVIRONMENT_ON_PURPOSE = {
    # An operator's removal must not wait for a reviewer's approval.
    ("app-release.yml", "secrets-rotate"),
}


def check_deploy_keys_stay_where_they_are(wfs: dict[str, dict]) -> list[str]:
    """SOPS_AGE_KEY and DEPLOY_SSH_KEY only in the jobs that deploy or rotate,
    and those jobs run in the target's GitHub Environment (SEC-01): that is
    where prod's required reviewers will apply. In particular the CaC jobs
    never get SOPS_AGE_KEY: with it, `sl cac apply` in CI would register the
    sops values, i.e. rotate keys (CAC-19)."""
    errors = []
    for name, wf in wfs.items():
        for job_id, job in jobs(wf).items():
            text = yaml.safe_dump(job)
            for secret, holders in KEY_HOLDERS.items():
                if f"secrets.{secret}" in text and (name, job_id) not in holders:
                    errors.append(f"{name}:{job_id}: reads {secret}, which only {sorted(holders)} may")
            holds = any(f"secrets.{k}" in text for k in KEY_HOLDERS)
            if holds and "environment" not in job and (name, job_id) not in NO_ENVIRONMENT_ON_PURPOSE:
                errors.append(f"{name}:{job_id}: holds a deploy key outside a GitHub Environment")
    return errors


# `run:` steps whose whole point is to run shell the CALLER wrote: the input
# is code by contract, from the caller's own reviewed workflow file.
SHELL_INPUTS_ON_PURPOSE = {
    ("foreign-timezone.yml", "${{ inputs.setup-command }}"),
    ("foreign-timezone.yml", "${{ inputs.test-command }}"),
    ("lib-release.yml", "${{ inputs.extra-ci-steps }}"),
    ("lib-release.yml", "${{ inputs.extra-ci-steps-post-build }}"),
}


def check_no_expressions_in_shell(wfs: dict[str, dict]) -> list[str]:
    """No `${{ }}` inside a `run:`: the template engine substitutes it before
    any shell exists, so quoting does not protect anything. Values reach the
    shell through `env:`. `github.event.*` (PR titles, branch names, commit
    messages) is the dangerous one; the rule covers every expression so a
    safe-looking one cannot turn into a dangerous one by a later edit."""
    errors = []
    for name, job_id, step, run in run_scripts(wfs):
        for expr in re.findall(r"\$\{\{[^}]*\}\}", run):
            if (name, expr) in SHELL_INPUTS_ON_PURPOSE:
                continue
            errors.append(f"{name}:{job_id}:{step}: `{expr}` is interpolated into the shell; pass it through env:")
    return errors


CHECKS = [
    check_parses,
    check_actions_pinned_by_sha,
    check_pin_comments_agree,
    check_no_unverified_installs,
    check_sops_is_verified_every_time,
    check_deploy_manual_deploys_the_tag,
    check_rollback_only_when_the_deploy_failed,
    check_stable_retag_cannot_fail_a_deploy,
    check_latest_is_validated,
    check_one_deploy_at_a_time_per_app_and_env,
    check_every_job_declares_permissions,
    check_app_tokens_are_narrow,
    check_untrusted_checkouts_keep_no_token,
    check_deploy_keys_stay_where_they_are,
    check_no_expressions_in_shell,
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
