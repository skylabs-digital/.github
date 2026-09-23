#!/usr/bin/env python3
"""Print the `run:` script of one step of a workflow job.

    extract_step.py <workflow.yml> <job> <step id or exact step name>

The behaviour tests execute the real script straight out of the workflow, so
what they test is what Actions runs: no copy that can drift.
"""
import sys

import yaml

path, job, key = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    wf = yaml.safe_load(f)
steps = wf["jobs"][job]["steps"]
for step in steps:
    if step.get("id") == key or step.get("name") == key:
        if "run" not in step:
            sys.exit(f"{path}: step {key!r} of job {job!r} has no run:")
        sys.stdout.write(step["run"])
        sys.exit(0)
sys.exit(f"{path}: no step {key!r} in job {job!r}")
