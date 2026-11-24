---
name: workhorse
description: Run a job on one of the user's workhorses, the spare Macs in the claude-workhorses hosts file, against a verified copy of the current git repo, with the `wh` command. Use it when the user names a workhorse or one of its hosts, or asks to offload, and on your own when you are about to run a full test suite, a full build or another job that takes minutes in a git repo, or when this machine is already busy. For git repos, use this instead of claude-tmux:remote-tests. Not for a single test file or a job that finishes in under 2 minutes.
---

# Workhorse

`wh` runs a command on a workhorse in a private copy of the current git repo, after bringing the copy
level with this machine, `.git` included. This machine stays free. A workhorse can be slower per core,
so offload to free this machine, never to go faster. The workhorse table printed at session start
lists each host with its architecture, cores, RAM and profile.

Each run adds a few seconds before the command starts: about 1.5 s on a small repo and 4 s on one of
70,000 files (5 to 6 s with every laptop core busy).
This machine's Watchman reports what changed here, and the host lists what the last job changed in
the copy, so a run patches only those paths. When Watchman is not installed or has restarted since
the copy's last run, `wh` says `full walk:` and compares every file instead (8 to 25 s on that large
repo, longer the busier this machine). The first run in a repo compares every file's contents (40 s
on that large repo). Copying `.git` adds about a second (0.6 to 1.3 s in dry runs over the LAN, a
54 GB `.git` included).

```bash
wh -- gtimeout 30m pnpm test          # a free host, by load
wh alpha -- gtimeout 20m cargo test   # a named host
```

- Run it from anywhere inside the repo. The command runs in the same subfolder of the copy. A fresh
  clone or worktree works at once.
- Every run shows up for the user in the sessions whose folder holds the repo, or sits inside it (the
  workhorse-runs mod): a green `wh` badge in the prompt footer, which names the host and counts the copy
  (`↗ wh - alpha 0:42`), then spins (`⠋ wh - alpha 0:43`) while the job runs, a line per run above the
  prompt (`wh alpha: pnpm test (demo) · 0:43`), at most three of them and a count of the rest, and a
  toast when one that took over 2 minutes ends or a run ends with `BLOCKED`.
- With no host, `wh` picks among the hosts whose 1-minute load is below their core count: one that
  already holds the repo's copy, then the lowest load per core. Name the host when the job needs
  x86_64 or arm64; the table's Arch column says which host has which.
- Always put `--` before the command. Bound every command with `gtimeout`.
- The hosts' default `node` is 24. A repo that needs Node 26 runs under mise:
  `wh -- gtimeout 30m mise exec node@26 -- npm test`. Headless browser tests find Chrome for Testing
  through `CHROME_BIN` (`~/.local/bin/chrome`), which every host sets.
- Run it from a background shell (`run_in_background: true`) when it takes minutes, and wait for the
  exit notification instead of polling.

## When to use it

Use it when any of these holds:

- The user names a workhorse or one of its hosts, or asks for a remote run.
- You are about to run a full suite or build that takes minutes, and nobody needs the result in the
  next 2 minutes.
- This machine's 1-minute load (`uptime`) is over 10.
- The job writes more than 5 GB.

Run it locally instead when the job needs over 10 GB of RAM, a GPU, code signing, API keys or other
environment variables set only on this machine (`wh` passes none), or Unity (a dedicated host's
editor has no license and exits 198; a shared host has no Unity). For arm64 output, name an arm64
host.

When the job needs a tool the hosts lack or have in too old a version (a runtime, a browser, a
command-line tool, Xcode or a simulator runtime), do not run it locally. Ask the user with
`AskUserQuestion` whether to install it, recommending the option that adds it to the provision
scripts for every host, runs `provision/sync.sh` and checks `provision/sync.sh diff`. Then run the
job with `wh`. Run it locally only if the user declines, and say so. Any git repo works; for a folder
that is not a git repo, follow the workhorse policy printed at session start.

## Git in the copy

`wh` copies this machine's `.git` before each run, so git in the copy has this machine's commits,
branch and index: `jest --onlyChanged`, `--changedSince`, `git describe` and diffs against a branch
give this machine's answer. Started from a linked worktree, the copy is an ordinary repository
holding the worktree's branch and index. Lock files (`*.lock`) stay on this machine.

## Exit codes

| Code | Meaning |
|------|---------|
| the command's own | The command ran; this is its result. |
| 3, with `BLOCKED` on stderr | The command did not run. The message says why: no host free or reachable, another run holds the lock, copying `.git` or the patch from this machine failed, git tracks files `wh` skips, or the repo's first copy on that host would send over 1 GB (`.git` and files together) through Tailscale (make it from a network that reaches the host without Tailscale, or name a host on this network). |
| 2 | Usage error: missing `--`, not inside a git repo, an unknown host, or a missing or bad hosts file. |

On 3, read the message and fix the cause. If no host is free or reachable, run the job locally and
tell the user.

## First run in a repo

The copy keeps installed dependencies between runs, but `wh` never carries `node_modules/`,
`target/`, `.venv/`, `venv/`, `Library/`, `.build/`, `.gradle/`, `DerivedData/` or `__pycache__/`.
The first time, install them on the host: `wh -- gtimeout 20m pnpm install --frozen-lockfile`.
Never copy built artifacts between architectures (an arm64 laptop and an x86_64 host, say). A
worktree's first copy on a host starts from that host's copy of the main checkout, `.git` included,
when there is one.

## Rules

- Edit on this machine only. Every run resets the copy on the host, which wipes any edit made there.
  A tool that edits a file and then puts back its size and modification time would hide that edit
  from the next run; no normal job does that.
- Leave the copies under `~/work/` on the hosts in place; other agents reuse them.
- No sudo or installs outside the copy on a host without asking the user.
- Bring back logs and reports, not built files.
