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
import textwrap

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


class TrustedScopeTests(unittest.TestCase):
    def bootstrap(self, trusted=True, event_name="push"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "Scripts/ci-scope.py"
            script.parent.mkdir()
            (root / "README.md").write_text("Synthetic CI repository\n")
            if trusted:
                script.write_text(Path(__file__).with_name("ci-scope.py").read_text())

            def git(*arguments):
                return subprocess.run(["git", "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", *arguments],
                    cwd=root, check=True, capture_output=True).stdout.decode().strip()

            git("init", "--quiet")
            git("add", ".")
            git("commit", "--quiet", "-m", "Trusted baseline")
            base = git("rev-parse", "HEAD")
            script.write_text('import os\nprint("POISONED PR CLASSIFIER")\nwith open(os.environ["GITHUB_OUTPUT"], "a") as f: f.write("core=false\\napp=false\\n")\n')
            git("add", ".")
            git("commit", "--quiet", "-m", "Poisoned candidate")
            event = root / "event.json"
            event.write_text(json.dumps({"before": base}))
            output = root / "output.txt"
            environment = dict(os.environ, GITHUB_EVENT_NAME=event_name, GITHUB_EVENT_PATH=str(event),
                GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_OUTPUT=str(output))
            workflow = Path(__file__).parent.parent / ".github/workflows/ci.yml"
            code = textwrap.dedent(workflow.read_text().split("# Trusted scope bootstrap\n", 1)[1].split("# End trusted scope bootstrap", 1)[0])
            result = subprocess.run([sys.executable, "-c", code], cwd=root, env=environment,
                check=True, capture_output=True, text=True)
            self.assertNotIn("POISONED PR CLASSIFIER", result.stdout)
            self.assertEqual(output.read_text(), "core=true\napp=true\n")

    def test_candidate_cannot_replace_the_trusted_classifier(self):
        self.bootstrap()

    def test_classifier_bootstrap_runs_full_without_a_trusted_version(self):
        self.bootstrap(trusted=False)

    def test_manual_dispatch_cannot_choose_a_cheap_route(self):
        self.bootstrap(event_name="workflow_dispatch")


if __name__ == "__main__":
    unittest.main()
