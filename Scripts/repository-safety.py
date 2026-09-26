#!/usr/bin/env python3
"""Fail on tracked private files or credential material; report paths only."""
import re
import subprocess
import sys
from pathlib import Path

paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
private_parts = {"private_outputs", ".agent", ".agent-local", ".agents", ".claude", ".codex", ".cursor", "transcripts", "xcuserdata"}
private_suffixes = (".store", ".store-wal", ".store-shm", ".sqlite", ".sqlite3", ".p8", ".p12", ".key")
credentials = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}")
failures = []
for raw in filter(None, paths):
    p = Path(raw)
    if (private_parts.intersection(p.parts) or raw.endswith(private_suffixes)
        or p.name.startswith(".env") and p.name != ".env.example"
        or p.name == "BankSync.local.xcconfig"
        or p.name.startswith("dev-") and p.name.endswith(".fixture.json")):
        failures.append((raw, "private file"))
        continue
    if p.is_file() and credentials.search(p.read_bytes()):
        failures.append((raw, "credential material"))
for path, reason in failures:
    print(f"FAIL: {path}: {reason}")
if failures:
    sys.exit(1)
print(f"PASS: {len(list(filter(None, paths)))} tracked paths checked; no private files or credential material")
