#!/usr/bin/env python3
"""Choose CI work from a complete diff; uncertain inputs always run every gate."""

import json
import os
from pathlib import Path
import re
import subprocess


def scope(paths: list[str]) -> tuple[bool, bool]:
    if not paths:
        return True, True
    core = app = False
    for path in paths:
        if path.startswith("docs/") or path in {"README.md", "AGENTS.md", "LICENSE", "LICENSE.md"}:
            continue
        if path.startswith(("FinanceApp/", "FinanceAppTests/", "FinanceAppUITests/", "FinanceApp.xcodeproj/")):
            app = True
        else:
            # Includes Core, workflows, scripts and every unrecognized path.
            # New build inputs cannot accidentally inherit a cheaper route.
            core = app = True
    return core, app


def event_scope() -> tuple[bool, bool]:
    try:
        event_name = os.environ["GITHUB_EVENT_NAME"]
        if event_name not in {"pull_request", "push"}:
            return True, True
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        base = event["pull_request"]["base"]["sha"] if event_name == "pull_request" else event["before"]
        head = os.environ["GITHUB_SHA"]
        for sha in (base, head):
            if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha) or sha == "0" * 40:
                return True, True
        diff = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, head, "--"],
            check=True, capture_output=True, timeout=20,
        ).stdout
        return scope([name.decode("utf-8", errors="strict") for name in diff.split(b"\0") if name])
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
        return True, True


def main() -> None:
    core, app = event_scope()
    print(f"CI scope: FinanceCore={'full' if core else 'unchanged'}; app/release={'full' if app else 'unchanged'}")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"core={str(core).lower()}\napp={str(app).lower()}\n")


if __name__ == "__main__":
    main()
