#!/usr/bin/env python3
# ABOUTME: Captures wh in a plain shell and in Claude Code, in a private tmux server, against one real workhorse.
# ABOUTME: Names the host alpha in every frame, keeps only the rows each image shows, and removes its copies on exit.

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from banner import build as build_banner
from render import THEMES, render


ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "assets/capture"
TMUX = shutil.which("tmux")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# The host's name in the hosts file and its ssh target; ssh-alias.sh sends alpha-mini to the real host.
HOST, ALIAS = "alpha", "alpha-mini"
TEST = "wh --timeout 5m -- go test -v ./..."
BENCH = "wh --timeout 5m -- go test -bench=. ./..."
EDIT = """echo 'func TestSub(t *testing.T) { if Sub(5, 3) != 2 { t.Fatal("Sub(5, 3) != 2") } }' >> calc_test.go"""
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
TITLES = {
    "wh-run": "wh runs a repository's tests on a workhorse, then runs them again after an edit",
    "claude-band": "The wh badge and band in Claude Code while a run goes",
}
DESCRIPTIONS = {
    "wh-run": "A terminal runs wh in a small Go repository. The first run picks the workhorse alpha, copies every "
              "file and runs the tests. After a one-line edit, the second run sends only the edited file. "
              "Each state lasts 2.5 seconds.",
    "claude-band": "Claude Code runs wh in bash mode. The band above the prompt names the run and its time; the "
                   "footer badge counts the copy, then spins while the job runs, and both go when it ends. "
                   "Each state lasts 2.5 seconds.",
}


def run(*args, env=None, check=True, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, env=env, check=check, capture_output=True, text=True)


def plain(text):
    return ANSI.sub("", text)


class Capture:
    def __init__(self, name):
        self.name = name
        self.target = os.environ.get("WH_CAPTURE_SSH_TARGET", "")
        if not self.target:
            raise RuntimeError("WH_CAPTURE_SSH_TARGET must name the workhorse's ssh target")
        # /tmp keeps the scratch path, which Claude Code and wh can print, free of any user name.
        self.work = Path(os.path.realpath(tempfile.mkdtemp(prefix="wh-capture-", dir="/tmp")))
        self.bin = self.work / "bin"
        self.config = self.work / "config"
        self.demos = []
        self.frames = []
        self.frame_index = 0
        self.theme = "light"
        self.started = False
        self.claude = shutil.which("claude")
        self.versions = {}

    def __enter__(self):
        try:
            return self.prepare()
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def prepare(self):
        if not TMUX:
            raise RuntimeError("tmux is required")
        for path in (self.bin, self.config, self.work / "tmp"):
            path.mkdir(parents=True)
        (self.bin / "ssh").symlink_to(CAPTURE / "ssh-alias.sh")
        # Claude Code runs a shell named bash; this one reads no personal startup files.
        (self.bin / "bash").symlink_to(CAPTURE / "shell.sh")
        path = f"{self.bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if self.name == "wh-run":
            # Claude Code puts the plugin's bin/ on its commands' PATH; a plain shell needs it added.
            path = f"{self.bin}:{ROOT / 'bin'}:{path.split(':', 1)[1]}"
        self.env = {
            "HOME": str(Path.home()), "USER": os.environ["USER"], "PATH": path,
            "TMPDIR": str(self.work / "tmp"), "TERM": "xterm-256color", "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8", "SHELL": "/bin/bash", "BASH_ENV": "/dev/null", "ENV": "/dev/null",
            "BASH_SILENCE_DEPRECATION_WARNING": "1", "PS1": "$ ",
            "CLAUDE_WORKHORSES_CONFIG_DIR": str(self.config), "WH_CAPTURE_SSH_TARGET": self.target,
            "CLAUDE_CODE_SHELL": str(self.bin / "bash"),
            "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        }
        existing = self.tmux("list-sessions", check=False)
        if existing.returncode == 0:
            raise RuntimeError("tmux -L svgcap already has sessions; refusing to touch them")
        facts = self.ssh("uname -m; sysctl -n hw.physicalcpu hw.memsize").split()
        arch, cores, memory = facts[0], facts[1], round(int(facts[2]) / 2**30)
        (self.config / "hosts").write_text(f"{HOST} {ALIAS} {arch} {cores} {memory}\n")
        self.versions["host"] = {"arch": arch, "cores": int(cores), "ram_gb": memory}
        self.versions["go"] = self.ssh("go version").strip()
        if self.name == "claude-band":
            if self.claude is None:
                raise RuntimeError("claude is required")
            self.versions["claude"] = run(self.claude, "--version", env=self.env).stdout.strip()
        return self

    def __exit__(self, kind, error, traceback):
        try:
            self.stop()
        finally:
            self.clean()
        if kind is None:
            shutil.rmtree(self.work)
        else:
            print(f"Capture records: {self.work}", flush=True)

    def ssh(self, command):
        return run(str(self.bin / "ssh"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ALIAS, command,
                   env=self.env).stdout

    def tmux(self, *args, check=True):
        return run(TMUX, "-L", "svgcap", *args, env=self.env, check=check)

    def demo(self):
        """A fresh git repository named demo, so each run is a first copy on the workhorse."""
        folder = Path(tempfile.mkdtemp(prefix="demo-", dir=self.work)) / "demo"
        shutil.copytree(CAPTURE / "demo", folder)
        identity = ["-c", "user.name=demo", "-c", "user.email=demo@example.invalid"]
        for args in (["init", "-q"], ["add", "."], [*identity, "commit", "-qm", "demo"]):
            run("git", *args, cwd=folder, env=self.env)
        self.demos.append(folder)
        return folder

    def clean(self):
        # The host keeps a copy per repository path, as mirror.sh names it: the folder's name and the first
        # 8 hex digits of the SHA-1 of its path. Only this capture's copies are removed, by exact name.
        names = []
        for folder in self.demos:
            digest = hashlib.sha1(str(folder).encode()).hexdigest()[:8]
            names += [f"work/demo-{digest}{suffix}" for suffix in ("", ".lock", ".clock", ".listing", ".times")]
            run("watchman", "watch-del", str(folder), env=self.env, check=False)
        if names:
            run(str(self.bin / "ssh"), "-o", "BatchMode=yes", ALIAS, "cd && rm -rf " + " ".join(names),
                env=self.env, check=False)
        self.demos = []

    def stop(self):
        if not self.started:
            return
        self.tmux("kill-server", check=False)
        self.started = False
        # A Claude Code process can outlive its terminal; this run's debug file names it.
        for line in run("/bin/ps", "-axo", "pid=,command=").stdout.splitlines():
            if str(self.work / "debug-") in line:
                try:
                    os.kill(int(line.split()[0]), signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def start(self, theme, folder, command):
        self.theme = theme
        fg, bg = THEMES[theme]
        config = self.work / "tmux.conf"
        config.write_text("set -g status off\nset -g focus-events on\nset -g remain-on-exit on\n"
                          "set -g default-shell /bin/bash\nset -g default-terminal xterm-256color\n"
                          f"set -g window-style 'fg={fg},bg={bg}'\nset -g history-limit 1000\n")
        self.tmux("-f", str(config), "new-session", "-d", "-s", "capture", "-x", "110", "-y", "40",
                  "-c", str(folder), *command)
        self.started = True

    def screen(self, *args):
        return self.tmux("capture-pane", "-t", "capture:0.0", "-p", *args).stdout

    def wait(self, test, seconds=120):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            text = plain(self.screen())
            if "Yes, I trust this folder" in text:
                # The trust dialog for the new folder defaults to No, exit; Enter goes only once Yes is selected.
                if "❯ Yes, I trust this folder" in text:
                    self.key("Enter")
                else:
                    time.sleep(1)
                    self.key("Down")
                continue
            if "Do you want to proceed?" in text:
                raise RuntimeError(f"A permission prompt appeared; capture is in {self.work}")
            if (test(text) if callable(test) else test in text):
                return text
            time.sleep(.1)
        (self.work / f"failure-{self.theme}.ansi").write_text(self.screen("-e"))
        raise RuntimeError(f"Never saw {test!r}; capture is in {self.work}")

    def prompt(self):
        return self.wait(lambda text: text.rstrip().splitlines()[-1] == "$")

    def key(self, *keys):
        self.tmux("send-keys", "-t", "capture:0.0", *keys)
        time.sleep(.4)

    def type(self, text):
        self.tmux("send-keys", "-t", "capture:0.0", "-l", text)
        time.sleep(.5)
        self.key("Enter")

    def save(self, label, first, check=None):
        lines = plain(self.screen()).splitlines()
        start = next((i for i, line in enumerate(lines) if first in line), None)
        if start is None:
            raise RuntimeError(f"Crop marker {first!r} missing for {label}")
        stop = len(lines)
        while stop > start and not lines[stop - 1].strip():
            stop -= 1
        # Only the rows the image shows are kept: Claude Code's welcome box names the account above them.
        raw = self.screen("-e", "-S", str(start), "-E", str(stop - 1))
        if check is not None:
            check(plain(raw))
        filename = f"{self.name}-{self.frame_index}-{self.theme}.ansi"
        (self.work / filename).write_text(raw.replace(str(Path.home()), "~"))
        item = {"file": filename, "crop": [0, stop - start]}
        if self.frame_index == len(self.frames):
            self.frames.append({"label": label, "captures": {}})
        elif self.frames[self.frame_index]["label"] != label:
            raise RuntimeError(f"Theme frame mismatch: {label}")
        self.frames[self.frame_index]["captures"][self.theme] = item
        self.frame_index += 1
        print(f"{self.theme}: {label}, {stop - start} rows", flush=True)

    def wh_run(self):
        folder = self.demo()
        self.start("dark", folder, ["/bin/bash", "--noprofile", "--norc"])
        self.prompt()
        self.type(TEST)
        self.save("wh sends the tests to a workhorse", "$ wh")
        self.wait("patched")
        self.save("The first run copies every file", "$ wh")
        self.prompt()
        self.type("echo $?")
        self.prompt()
        self.save("The tests pass, and wh exits with their exit code", "$ wh")
        self.type(EDIT)
        self.prompt()
        self.type(TEST)
        self.wait(lambda text: text.count("using alpha") == 2)
        self.save("An edit, then the same command", "$ wh")
        self.wait(lambda text: text.count("ok  ") == 2)
        self.prompt()
        self.type("echo $?")
        self.prompt()
        self.save("The second run sends only the edited file", "$ wh",
                  check=lambda text: self.expect("patched 1 files from the laptop" in text, "one patched file"))
        # The shell prints no colors of its own: one capture serves both themes, which set its default colors.
        for frame in self.frames:
            frame["captures"]["light"] = frame["captures"]["dark"]

    def expect(self, condition, what):
        if not condition:
            raise RuntimeError(f"Capture check failed: {what}; capture is in {self.work}")

    def band(self, running):
        def check(text):
            lines = text.splitlines()
            self.expect(sum(line.startswith(f"↗ workhorses │ {HOST} · ") for line in lines) == (1 if running else 0),
                        f"{'one' if running else 'no'} band line")
            self.expect(text.count(f"wh - {HOST}") == (1 if running else 0), f"{'one' if running else 'no'} badge")
        return check

    def claude_band(self, theme):
        folder = self.demo()
        settings = self.work / f"{theme}.json"
        # An installed copy of the workhorse-runs mod would draw every line twice.
        settings.write_text(json.dumps({"theme": theme, "enabledPlugins": {"workhorse-runs@skills-dir": False}}))
        self.start(theme, folder, [
            self.claude, "--plugin-dir", str(ROOT), "--model", "haiku",
            "--setting-sources", "", "--settings", str(settings), "--strict-mcp-config",
            "--debug-file", str(self.work / f"debug-{theme}.log"),
            "--append-system-prompt",
            "This is a terminal capture. After a shell command finishes, reply with one short sentence "
            "about its result. Run nothing yourself, and address nobody by name."])
        # The empty prompt; the trust dialog's "❯ No, exit" is not it.
        self.wait(lambda text: any(line.strip() == "❯" for line in text.splitlines()))
        time.sleep(2)
        self.tmux("send-keys", "-t", "capture:0.0", "-l", "!")
        time.sleep(.5)
        self.type(BENCH)
        self.wait(f"↗ wh - {HOST}")
        self.save("The badge counts the copy to the workhorse", "! wh --", self.band(True))
        self.wait(lambda text: re.search(f"[{SPINNER}] wh - {HOST}", text) is not None)
        self.save("The badge spins while the job runs", "! wh --", self.band(True))
        self.wait("ns/op")
        self.save("The band counts the run's time", "! wh --", self.band(True))
        self.wait(lambda text: f"wh - {HOST}" not in text and "ok  " in text)
        self.save("The run ends, and the band and badge go", "! wh --", self.band(False))

    def finish(self):
        manifest = self.work / f"{self.name}.json"
        data = {
            "title": TITLES[self.name],
            "description": DESCRIPTIONS[self.name],
            "provenance": {
                "checkout_head": run("git", "rev-parse", "HEAD").stdout.strip(),
                "host": f"{HOST}, a real workhorse; its ssh target stays outside the capture",
                "versions": self.versions,
                "commands": [TEST, EDIT, TEST] if self.name == "wh-run" else [f"! {BENCH}"],
                "capture_commands": [f"bash assets/capture/{self.name}.sh", "tmux -L svgcap capture-pane -p -e"],
                "crop": "Each file holds only the rows its frame shows, captured with -S and -E; all 110 columns remain.",
                "themes": "One capture serves both themes; the shell prints no colors of its own."
                          if self.name == "wh-run" else "Each theme is its own Claude Code session and run.",
                "terminal_defaults": THEMES,
                "home_path": "The current home directory prefix is replaced with ~ when capture files are written.",
            },
            "frames": self.frames,
        }
        manifest.write_text(json.dumps(data, indent=2) + "\n")
        svg = self.work / f"{self.name}.svg"
        render(manifest, svg)
        files = [manifest, svg, *{self.work / c["file"] for f in self.frames for c in f["captures"].values()}]
        # Names kept out of the repository reach the check through WH_PRIVACY_PATTERNS, when it is set.
        patterns = {"WH_PRIVACY_PATTERNS": os.environ["WH_PRIVACY_PATTERNS"]} if "WH_PRIVACY_PATTERNS" in os.environ else {}
        check = run(sys.executable, "-B", str(CAPTURE / "check-privacy.py"), *map(str, files),
                    env={**self.env, **patterns}, check=False)
        if check.returncode != 0:
            raise RuntimeError(f"The privacy check failed:\n{check.stdout}{check.stderr}capture is in {self.work}")
        for path in files[2:]:
            shutil.copyfile(path, CAPTURE / path.name)
        shutil.copyfile(manifest, CAPTURE / manifest.name)
        if self.name == "wh-run":
            (ROOT / "assets/banner.svg").write_text(build_banner(svg.read_text()))
        else:
            shutil.copyfile(svg, ROOT / "assets" / svg.name)


if __name__ == "__main__":
    def interrupt(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    parser = argparse.ArgumentParser()
    parser.add_argument("name", choices=TITLES)
    args = parser.parse_args()
    with Capture(args.name) as capture:
        if args.name == "wh-run":
            capture.wh_run()
        else:
            for theme in THEMES:
                capture.frame_index = 0
                capture.claude_band(theme)
                capture.stop()
        capture.finish()
