#!/usr/bin/env python3
"""Exercise scope decisions that could suppress a required build."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("ci_scope", Path(__file__).with_name("ci-scope.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ScopeTests(unittest.TestCase):
    def test_only_repository_documentation_uses_linux(self):
        self.assertEqual(module.scope(["docs/architecture.md", "README.md", "AGENTS.md"]), (False, False))

    def test_app_changes_keep_app_and_release_gates(self):
        for path in ["FinanceApp/Persistence/FinanceStore.swift", "FinanceAppTests/Test.swift",
                     "FinanceAppUITests/Test.swift", "FinanceApp.xcodeproj/project.pbxproj",
                     "FinanceApp/Resources/README.md"]:
            self.assertEqual(module.scope(["docs/plan.md", path]), (False, True))

    def test_core_and_unrecognized_inputs_run_all_gates(self):
        for path in ["Packages/FinanceCore/Sources/Core.swift", ".github/workflows/ci.yml",
                     "Scripts/release-gate", "NewPackage/Package.swift", ".swift-version"]:
            self.assertEqual(module.scope([path]), (True, True))

    def test_empty_diff_runs_all_gates(self):
        self.assertEqual(module.scope([]), (True, True))

    def event(self, event_name, payload, head="b" * 40):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "event.json"
        path.write_text(json.dumps(payload))
        return patch.dict(os.environ, {"GITHUB_EVENT_NAME": event_name, "GITHUB_EVENT_PATH": str(path), "GITHUB_SHA": head})

    def test_pull_request_uses_base_to_checked_out_merge(self):
        with self.event("pull_request", {"pull_request": {"base": {"sha": "a" * 40}}}), \
             patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"docs/a.md\0")) as run:
            self.assertEqual(module.event_scope(), (False, False))
            self.assertEqual(run.call_args.args[0][-3:], ["a" * 40, "b" * 40, "--"])

    def test_deleted_and_renamed_source_cannot_hide_in_docs(self):
        with self.event("push", {"before": "a" * 40}), \
             patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"FinanceApp/Old.swift\0docs/Old.swift\0")):
            self.assertEqual(module.event_scope(), (False, True))

    def test_manual_dispatch_always_runs_all_gates(self):
        with self.event("workflow_dispatch", {}), patch.object(module.subprocess, "run") as run:
            self.assertEqual(module.event_scope(), (True, True))
            run.assert_not_called()

    def test_invalid_or_initial_commit_runs_all_gates(self):
        for base in ["0" * 40, "--help", None]:
            with self.event("push", {"before": base}), patch.object(module.subprocess, "run") as run:
                self.assertEqual(module.event_scope(), (True, True))
                run.assert_not_called()

    def test_unavailable_history_runs_all_gates(self):
        with self.event("push", {"before": "a" * 40}), \
             patch.object(module.subprocess, "run", side_effect=subprocess.CalledProcessError(128, "git")):
            self.assertEqual(module.event_scope(), (True, True))

    def test_malformed_event_shape_runs_all_gates(self):
        for payload in [[], {"pull_request": None}, {"pull_request": {"base": None}}]:
            with self.event("pull_request", payload), patch.object(module.subprocess, "run") as run:
                self.assertEqual(module.event_scope(), (True, True))
                run.assert_not_called()

    def test_unknown_filename_encoding_runs_all_gates(self):
        with self.event("push", {"before": "a" * 40}), \
             patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"\xff\0")):
            self.assertEqual(module.event_scope(), (True, True))


if __name__ == "__main__":
    unittest.main()
