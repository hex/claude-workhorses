#!/usr/bin/env python3
# ABOUTME: Fails when a capture file holds an address, a host or user name, a home path, an email or plan text.
# ABOUTME: Usage: check-privacy.py [file...]; with no files it checks every file under assets/. Prints file:line and the kind, never the match.

import os
import re
import socket
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SELF = Path(__file__).resolve()
SGR = re.compile(r"\x1b\[[0-9;]*m")
# Addresses that may appear: the reserved example domains and the GitHub noreply form.
ALLOWED_EMAIL = re.compile(r"@(example\.(com|org|net|test|invalid)|[a-z0-9.-]+\.example\.test|users\.noreply\.github\.com)$", re.I)

KINDS = [
    ("IPv4 address", r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    ("IPv6 address", r"\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b|\b[0-9a-f]{1,4}::[0-9a-f]{0,4}\b"),
    ("ssh connection notice", r"Connection to \S+ port \d+|\bsucceeded!"),
    (".local host name", r"[A-Za-z0-9-]\.local\b"),
    ("tailnet name", r"\.ts\.net\b"),
    ("home path", r"/Users/|/home/[A-Za-z]|/var/folders/|/private/tmp/claude-\d+"),
    ("plan or account text", r"\bClaude (?:Max|Pro|Team|Ultra|Enterprise)\b|API Usage Billing|\bOrganization\b"),
]


def personal_words():
    """Names this machine and this user would leak: the user, the home folder, the machine, the git email,
    the capture's ssh target, and one regular expression per line of WH_PRIVACY_PATTERNS, a file kept
    outside the repository for names that must not be published even as a pattern."""
    words = set()
    user = os.environ.get("USER", "")
    words.update(part for part in re.split(r"[._-]", user) if len(part) >= 3)
    words.add(Path.home().name)
    words.add(socket.gethostname().split(".")[0])
    target = os.environ.get("WH_CAPTURE_SSH_TARGET", "")
    if target:
        login, _, host = target.rpartition("@")
        words.update(filter(None, (login, host, host.split(".")[0])))
    email = subprocess.run(["git", "config", "--global", "user.email"], capture_output=True, text=True).stdout.strip()
    if email:
        words.add(email)
    patterns = [rf"(?<![A-Za-z0-9]){re.escape(word)}(?![A-Za-z0-9])" for word in words if len(word) >= 3]
    extra = os.environ.get("WH_PRIVACY_PATTERNS")
    if extra:
        patterns += [line.strip() for line in Path(extra).read_text().splitlines()
                     if line.strip() and not line.startswith("#")]
    return patterns


def scan(path, kinds):
    hits = []
    text = SGR.sub("", path.read_text(errors="replace"))
    for number, line in enumerate(text.splitlines(), 1):
        for kind, pattern in kinds:
            if pattern.search(line):
                hits.append(f"{path}:{number}: {kind}")
        for match in re.finditer(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", line):
            if not ALLOWED_EMAIL.search(match[0]):
                hits.append(f"{path}:{number}: email address")
    return hits


def main(args):
    kinds = [(kind, re.compile(pattern)) for kind, pattern in KINDS]
    kinds += [("personal name", re.compile(pattern, re.I)) for pattern in personal_words()]
    if args:
        files = [Path(arg) for arg in args]
    else:
        files = sorted(p for p in (ROOT / "assets").rglob("*") if p.is_file() and p.suffix != ".png")
    files = [path for path in files if path.resolve() != SELF]
    hits = [hit for path in files for hit in scan(path, kinds)]
    for hit in hits:
        print(hit)
    print(f"{len(files)} files checked, {len(hits)} hits", file=sys.stderr)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
