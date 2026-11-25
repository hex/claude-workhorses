# Workhorses

This machine drives agents. Long jobs nobody is waiting on, and jobs that would crowd this machine,
run on a workhorse instead. These are the workhorses, from the claude-workhorses hosts file:

@HOSTS@

@TOOLS@

A workhorse can be slower per core than this machine, so never offload a job to make it faster;
offload it to keep this machine free.

Change a workhorse only through sync.sh. The user's tools file, `@CONFIG@/tools`, lists what each
host gets: one recipe and its arguments per line, with optional `@arch=`, `@os=` and `@hosts=` filters.
`bash @SYNC@` brings every host (or the hosts named after it) to that list; `bash @SYNC@ status` says
how each run ended and stores the record this policy's tool list comes from; confirm with
`bash @SYNC@ diff`. The workhorse skill names the built-in recipes. Never install a tool on one host
by hand.

- Offload when any of these holds: the job runs over 5 minutes and nobody is waiting on it; a heavy
  job is already running on this machine (`uptime` 1-minute load over its core count); the job
  writes more than 5 GB.
- Stay local when the job needs more RAM than the hosts have, a GPU or code signing, or when it
  finishes in under 2 minutes locally.
- A job that should offload but needs a tool the hosts lack or have in too old a version (a runtime,
  a browser, a command-line tool) does not fall back to this machine. Follow the workhorse skill's
  missing-tool steps: show the user the exact tools line, or the recipe's full text, with
  `AskUserQuestion`, never in prose, before sync.sh runs; the recommended option adds the
  line, syncs the hosts it targets and confirms with `bash @SYNC@ diff`, then offloads the job. Run
  locally only if the user declines, and say so. A job that needs arm64 output goes to an arm64 host
  or stays local; one that needs x86_64 goes to an x86_64 host. A job that needs macOS goes to a Mac
  and one that needs Linux to a Linux host; each host's record above names its system.
- In a git repository, run the job with `wh [host] [--timeout <limit>] -- <command...>` from
  anywhere inside the repo, for example `wh --timeout 30m -- pnpm test`, from a background shell;
  the `workhorse` skill has the details. With no host, `wh` asks every host at once and picks,
  among those whose 1-minute load is below their core count, one that already holds the repo's copy,
  then the lowest load per core. Name the host when the job needs one architecture or a tool only
  some hosts have. `wh` calls `@MIRROR@ run`, which locks `~/work/<repo>-<first 8 chars of the
  sha1 of the local absolute path>/` on the host, copies this machine's `.git` there and patches the
  working tree from this machine, then runs the command in the same subfolder. A linked worktree's
  copy becomes an ordinary repository with the worktree's branch and index, so git works in it. The
  first run compares every file's contents; later runs patch only the paths this machine's Watchman
  saw change plus those the last job changed in the copy, and fall back to comparing every file's
  size and modification time (stderr says `full walk:` and why) when Watchman is missing or has
  restarted. Its exit code is the command's; 124 means the command ran past `--timeout` and `wh`
  stopped it; exit 3 with `BLOCKED` means the command did not run (no free host, another run holds the
  lock, the copy or patch failed, git tracks files under a skipped name, or a first copy of over
  1 GB, `.git` and files together, would cross Tailscale); exit 2 is a usage error or a missing or
  bad hosts file. Make a large repo's first copy on a host from a network that reaches it without
  Tailscale.
- `wh` skips `node_modules/`, `target/`, `.venv/`, `venv/`, `Library/`, `.build/`, `.gradle/`,
  `DerivedData/`, `__pycache__/`, `.DS_Store` and `.cs/`. Install dependencies on the host inside
  the work copy, where they survive between runs; never copy built artifacts between architectures.
  Bound every job with `--timeout`.
- For a folder that is not a git repository, pick a host that has what the job needs, answers
  `ssh -o BatchMode=yes -o ConnectTimeout=5 <ssh> uptime` and shows a 1-minute load below its core
  count; if none qualifies, run locally and say so, and never wait on a host that is down. Sync the
  folder with `rsync -az --delete` to `~/work/<repo>-<sha8>/` named as above, with the same
  exclusions. Take the lock with `mkdir <dir>.lock` before syncing, write this machine's name, the
  time and the job into `<dir>.lock/owner`, and remove the lock when the job ends; if the lock
  exists, another agent owns the directory, so do not sync over it. Run detached
  (`nohup`, or a tmux session named after the directory), with output in `run.log` and the exit code
  in `run.status`. The exit code is the verdict. Wait from a background shell, not by polling in the
  foreground.
- Bring back logs and reports only. Edits happen on this machine; the remote copy is disposable.
- Every agent that tests a repo shares the work copy `mirror.sh run` made for it, and that copy
  keeps its installed dependencies, so leave it in place. An rsync directory is this session's disk:
  delete it when the work ends. Delete nothing on a workhorse that this session did not create.
  Before deleting anything on a host that a job could read, list `~/work/*.lock` and read each
  lock's `owner` file; while a lock this session did not take is there, a run may be reading those
  files, so wait for it to go.
- No sudo and no installs outside the remote directory on a workhorse without asking the user.

@NOTES@
