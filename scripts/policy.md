# Workhorses

This machine drives agents. Long jobs nobody is waiting on, and jobs that would crowd this machine,
run on a workhorse instead. These are the workhorses, from the claude-workhorses hosts file:

@HOSTS@

Every host carries the same tools, installed by the plugin's provision scripts: `git-lfs`, `cmake`,
`ninja`, node 24 (node 26 through `mise exec node@26 --`), Chrome for Testing (`CHROME_BIN`), bun,
pnpm, go, rust, .NET 10, JDK 21, `fastlane`, `ffmpeg`, `claude`, `codex`, `opencode` and
`macos-harness`. No host has Xcode, code signing, a GPU or Homebrew. A dedicated host is the
workhorse's alone and has the Unity 6000.3 editor but no Unity license, so the editor exits 198, tests
included. A shared host is its owner's Mac too: the same tools, no Unity, and its login, remote
access, firewall and network settings stay the owner's. Dedicated hosts are identical by design.

A workhorse can be slower per core than this machine, so never offload a job to make it faster;
offload it to keep this machine free.

Change a workhorse only through the provision scripts. `bash @SYNC@` brings every host (or the hosts
named after it) to what the installed scripts describe; confirm with `bash @SYNC@ diff`. Adding a tool
means editing `provision/tools.sh` in a checkout of the claude-workhorses repository and running that
checkout's `provision/sync.sh`, because a plugin update replaces the installed copy. Never install a
tool on one host by hand.

- Offload when any of these holds: the job runs over 5 minutes and nobody is waiting on it; a heavy
  job is already running on this machine (`uptime` 1-minute load over 10); the job writes more than
  5 GB.
- Stay local when the job needs over 10 GB RAM, a GPU, code signing or a Unity license; or when it
  finishes in under 2 minutes locally.
- A job that should offload but needs a tool the hosts lack or have in too old a version (a runtime,
  a browser, a command-line tool, Xcode or a simulator runtime) does not fall back to this machine.
  Ask the user with `AskUserQuestion`, never in prose, whether to install it; the recommended option
  adds it to the provision scripts so every host gets it, runs `provision/sync.sh`, confirms with
  `provision/sync.sh diff`, then offloads the job. Never install on one host only. Run locally only
  if the user declines, and say so. A job that needs arm64 output goes to an arm64 host or stays
  local; one that needs x86_64 goes to an x86_64 host.
- In a git repository, run the job with `wh [host] -- <command...>` from anywhere inside the repo,
  for example `wh -- gtimeout 30m pnpm test`, from a background shell; the `workhorse` skill has the
  details. With no host, `wh` asks every host at once and picks, among those whose 1-minute load is
  below their core count, one that already holds the repo's copy, then the lowest load per core.
  Name the host when the job needs one architecture or a tool only some hosts have. `wh` calls
  `@MIRROR@ run`, which locks `~/work/<repo>-<first 8 chars of the sha1 of the local absolute
  path>/` on the host, copies this machine's `.git` there and patches the working tree from this
  machine, then runs the command in the same subfolder. A linked worktree's copy becomes an ordinary
  repository with the worktree's branch and index, so git works in it. The first run compares every
  file's contents; later runs patch only the paths this machine's Watchman saw change plus those the
  last job changed in the copy, and fall back to comparing every file's size and modification time
  (stderr says `full walk:` and why) when Watchman is missing or has restarted. Its exit code is the
  command's; exit 3 with `BLOCKED` means the command did not run (no free host, another run holds
  the lock, the copy or patch failed, git tracks files under a skipped name, or a first copy of over
  1 GB, `.git` and files together, would cross Tailscale); exit 2 is a usage error or a missing or
  bad hosts file. Make a large repo's first copy on a host from a network that reaches it without
  Tailscale.
- `wh` skips `node_modules/`, `target/`, `.venv/`, `venv/`, `Library/`, `.build/`, `.gradle/`,
  `DerivedData/`, `__pycache__/`, `.DS_Store` and `.cs/`. Install dependencies on the host inside
  the work copy, where they survive between runs; never copy built artifacts between architectures.
  Bound every command with `gtimeout`.
- For a folder that is not a git repository, pick a host that has what the job needs, answers
  `ssh -o BatchMode=yes -o ConnectTimeout=5 <ssh> uptime` and shows a 1-minute load below its core
  count; if none qualifies, run locally and say so, and never wait on a host that is down. Sync the
  folder with `rsync -az --delete` to `~/work/<repo>-<sha8>/` named as above, with the same
  exclusions. Take the lock with `mkdir <dir>.lock` before syncing and remove it when the job ends;
  if the lock exists, another agent owns the directory, so do not sync over it. Run detached
  (`nohup`, or a tmux session named after the directory), with output in `run.log` and the exit code
  in `run.status`. The exit code is the verdict. Wait from a background shell, not by polling in the
  foreground.
- Bring back logs and reports only. Edits happen on this machine; the remote copy is disposable.
- Every agent that tests a repo shares the work copy `mirror.sh run` made for it, and that copy
  keeps its installed dependencies, so leave it in place. An rsync directory is this session's disk:
  delete it when the work ends. Delete nothing on a workhorse that this session did not create.
- No sudo and no installs outside the remote directory on a workhorse without asking the user.
