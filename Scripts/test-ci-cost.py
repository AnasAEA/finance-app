#!/usr/bin/env python3
"""Check estimate boundaries that otherwise hide runner consumption."""
import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("cost", Path(__file__).with_name("ci-cost.py"))
cost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cost)


class CostTests(unittest.TestCase):
    def job(self, seconds=61, labels=None):
        return dict(labels=labels or ["macos-latest"], steps=[{}],
                    started_at="2026-09-27T10:00:00Z",
                    completed_at=f"2026-09-27T10:{seconds // 60:02}:{seconds % 60:02}Z")

    def test_partial_minutes_round_up(self):
        self.assertEqual(cost.estimate(self.job()), ("macos-latest", 2, 0.124))

    def test_exact_minute_is_not_rounded_twice(self):
        self.assertEqual(cost.estimate(self.job(60))[1], 1)

    def test_cancelled_jobs_still_count_executed_time(self):
        job = self.job()
        job["conclusion"] = "cancelled"
        self.assertEqual(cost.estimate(job)[1], 2)

    def test_self_hosted_is_not_macos_hosted(self):
        self.assertEqual(cost.estimate(self.job(labels=["self-hosted", "macOS", "ARM64"])),
                         ("self-hosted", 0, 0.0))

    def test_rejected_before_execution_is_not_paid_work(self):
        job = self.job()
        job.update(steps=[], status="completed", conclusion="failure", runner_id=0)
        self.assertEqual(cost.estimate(job)[2], 0)

    def test_queued_hosted_job_without_steps_is_not_a_false_zero(self):
        job = self.job() | {"steps": [], "status": "queued", "conclusion": None}
        with self.assertRaises(ValueError):
            cost.estimate(job)

    def test_unknown_or_running_hosted_job_cannot_be_reported_as_zero(self):
        for job in [self.job(labels=["macos-latest-xlarge"]), self.job() | {"completed_at": None}]:
            with self.assertRaises(ValueError):
                cost.estimate(job)


if __name__ == "__main__":
    unittest.main()
