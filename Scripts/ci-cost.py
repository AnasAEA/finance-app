#!/usr/bin/env python3
"""Report gross runner estimates, including cancelled jobs and every attempt.

This is repository usage, not the account invoice or remaining paid allowance.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import math
import subprocess

RATES = {"macos-latest": 0.062, "ubuntu-24.04": 0.006}


def estimate(job):
    labels = job.get("labels", [])
    if "self-hosted" in labels:
        return "self-hosted", 0, 0.0
    # Rejected/skipped jobs with no steps did not execute on a runner.
    if not job.get("steps"):
        if job.get("status") != "completed" or job.get("conclusion") not in {"failure", "skipped", "cancelled"} or job.get("runner_id") != 0:
            raise ValueError("Runner execution is not yet known; refuse a zero estimate.")
        return "not executed", 0, 0.0
    label = next((label for label in labels if label in RATES), None)
    if label is None:
        raise ValueError(f"Unknown hosted runner labels: {labels}; verify its rate.")
    if not job.get("completed_at"):
        raise ValueError("A hosted job is still running; final cost is unavailable.")
    start = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
    if end < start:
        raise ValueError("Invalid runner timestamps.")
    minutes = math.ceil((end - start).total_seconds() / 60)
    return label, minutes, minutes * RATES[label]


def pages(path):
    result = subprocess.run(["gh", "api", "--paginate", "--slurp", path],
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", default=datetime.now(timezone.utc).strftime("%Y-%m-01"))
    parser.add_argument("--max-estimate", type=float, help="Exit nonzero when gross estimate reaches this USD amount")
    args = parser.parse_args()
    datetime.strptime(args.since, "%Y-%m-%d")
    prefix = "repos/AnasAEA/finance-app/actions"
    runs = [r for page in pages(f"{prefix}/runs?per_page=100&created=>={args.since}")
            for r in page["workflow_runs"] if r["name"] == "CI"]
    amounts = Counter()
    minutes = Counter()
    for run in runs:
        for page in pages(f"{prefix}/runs/{run['id']}/jobs?filter=all&per_page=100"):
            for job in page["jobs"]:
                runner, duration, amount = estimate(job)
                amounts[(runner, job["name"])] += amount
                minutes[runner] += duration
    for (runner, name), amount in sorted(amounts.items()):
        print(f"{runner:16} {name:28} ${amount:.3f}")
    total = sum(amounts.values())
    print(f"Since {args.since}: {len(runs)} CI runs; rounded hosted minutes {dict(minutes)}")
    print(f"Gross estimate ${total:.3f}; excludes discounts, other repositories and non-CI products.")
    print("Check GitHub Billing for actual net spend. Rates must be rechecked when runner pricing changes.")
    if args.max_estimate is not None and total >= args.max_estimate:
        raise SystemExit("Gross estimate reached the requested limit; stop and review usage.")


if __name__ == "__main__":
    main()
