<p align="center">
  <img src="assets/banner.svg" alt="The workhorses horse in front of a terminal where wh picks the workhorse alpha, copies a small Go module to it and runs its tests, then after a one-line edit sends only the edited file and runs them again">
</p>

<h1 align="center">workhorses</h1>

<p align="center">Long jobs run on your spare Macs while this one stays free.</p>

A plugin for Claude Code, Codex, pi, OpenCode, Antigravity, GitHub Copilot CLI, Cursor, VS Code, Grok Build and Kimi Code that runs long jobs on your spare Macs, or on Linux machines, a Windows PC's
Windows Subsystem for Linux (WSL2) included. `wh` copies the git repository you are in to a workhorse, brings the copy level with your machine (`.git` included), and runs the command
there. The test suite or the build runs on the workhorse, and your laptop stays free for the work in
front of you.

[![Tests](https://github.com/hex/workhorses/actions/workflows/tests.yml/badge.svg)](https://github.com/hex/workhorses/actions/workflows/tests.yml)

## Where it runs

| Where | What you get |
| --- | --- |
| Claude Code on your Mac | `wh` on the path of every command Claude runs, the offload policy and your host table at the start of every session, the `workhorse` skill, and the badge and band. |
| Codex, pi, OpenCode or Antigravity on your Mac | The offload policy and your host table in every session, which give `wh`'s full path, and the `workhorse` skill. No badge, band or `/workhorses:setup`: those are Claude Code's. |
| GitHub Copilot CLI on your Mac | The offload policy and your host table at the start of an interactive session, and the `workhorse` skill. |
| Cursor or VS Code on your Mac | Verified npx installs include the skill and startup hook. Enable plugin hooks and, in Cursor, third-party imports. Live startup remains unverified in both. |
| Grok Build or Kimi Code on your Mac | Grok listed the workhorse skill in a live session. Its installed startup hook runs, but Grok leaves the output out of model context. Kimi’s installed startup hook returned the policy in `additionalContext`, and its manifest registers the startup skill. The suspended account prevented a live session. |
| Your own terminal | `wh` by its full path, or linked into a folder on your `PATH`. Its runs show in the badge and band of a Claude Code session whose folder holds the repository or sits inside it. |
| The workhorses | Spare Macs, Intel or Apple silicon, with Remote Login on, or Linux machines with sshd. `wh` reaches them over ssh and needs nothing installed on a Mac; see [Linux and WSL hosts](#linux-and-wsl-hosts) for Linux. `sync.sh` gives each one the tools you list. |

Grok Build and Cursor rely on the workhorse skill to read the policy before choosing a host.
Grok ignores stdout from passive hooks by design. Cursor staff confirmed a timing bug that
drops startup context. [Grok hook behavior](https://docs.x.ai/build/features/hooks) · [Cursor staff confirmation](https://forum.cursor.com/t/sessionstart-hook-additional-context-is-never-injected-into-agents-initial-system-context/158452)

## Install

```bash
npx plugins add hex/workhorses
```

For a new install, npx offers the agents it detects. If you already installed workhorses from a
marketplace, keep that install. Running npx for the same agent can leave you with two copies.
Cursor reads Claude Code's plugins, so the `cursor` target also adds a copy to Claude Code. If
Claude Code already has workhorses, leave Cursor out of the npx run.
To pick just one target, add its ID, for example `npx plugins add hex/workhorses --target github-copilot`.

Use the native installer for pi, OpenCode and Antigravity.

| Agent | Install |
| --- | --- |
| pi | `pi install git:github.com/hex/workhorses` |
| OpenCode | `opencode plugin add github:hex/workhorses`, or the path of a clone under `plugins` in `opencode.json` |
| Antigravity | `agy plugin install <folder>` on a clone of this repository |

Rerun the same npx command to update the selected targets. Claude Code and Cursor share one plugin
cache. Codex refreshes its `plugins-cli` copy. For GitHub Copilot CLI, VS Code and Kimi Code,
npx refreshes the directories it registered. `copilot plugin update` does not refresh that copy.
For a Grok Build install from GitHub, npx calls `grok plugin update workhorses` on the next add.

Codex asks you to trust the startup hook in `/hooks`. GitHub Copilot CLI reads the policy only in
interactive sessions. `copilot -p` skips the hook.

### Marketplace alternatives

| Agent | Install |
| --- | --- |
| Claude Code | Run `/plugin marketplace add hex/claude-marketplace`, then `/plugin install workhorses`. |
| Codex | Run `codex plugin marketplace add hex/claude-marketplace`, then `codex plugin add workhorses@hex-plugins`. |

### Requirements

- macOS on the machine you work on, with `jq`, `rsync` and `ssh`.
  [Watchman](https://facebook.github.io/watchman/) makes later runs faster. Without it, every run
  compares each file's size and modification time.
- One or more Macs as workhorses, Intel or Apple silicon, with Remote Login on and your ssh key
  accepted by the workhorse user, or Linux hosts as [Linux and WSL hosts](#linux-and-wsl-hosts)
  describes.

All supported agents read the same workhorses hosts file and tool records, so you only need to configure the hosts once.

## First run

1. In Claude Code, from a git repository, run `/workhorses:setup` with your hosts' ssh
   targets:

   ```text
   /workhorses:setup alpha-mini me@gamma.example.test
   ```

   It asks each host for its architecture, cores and RAM, shows you the lines it would add to
   `~/.config/workhorses/hosts`, and on your yes adds them and runs a first job on each host.
   It installs nothing.
2. Or write the hosts file yourself. One host per line: name, ssh target, arch, cores, RAM in GB,
   then any [host options](#host-options).

   ```text
   # name  ssh target             arch    cores  RAM  options
   alpha   alpha-mini             x86_64  6      16   no-sleep maxfiles
   gamma   me@gamma.example.test  arm64   10     16
   ```

   [examples/hosts](examples/hosts) explains each field. The ssh target is an alias from
   `~/.ssh/config` or `user@host`, so addresses and routes stay in your ssh config. Check that each
   host answers: `ssh -o BatchMode=yes alpha-mini uptime`.
3. In a git repository, run something small:

   ```bash
   wh --timeout 5m -- git log -1 --oneline
   ```

   The first run in a repository copies every file. Later runs send only what changed. A Mac without
   Apple's Command Line Tools has no working `git`; the next step installs them.
4. When a job needs a tool a host lacks, Claude proposes a line for your tools file and asks before
   anything changes. See [Provisioning](#provisioning).

## Features

| Capability | Guide |
| --- | --- |
| Run a command on a workhorse, in a copy of the repository you are in, and get its exit code back | [Running a job](#running-a-job) |
| Let `wh` pick the host with room, or name one or more | [Choosing a host](#choosing-a-host) |
| Send only what changed since the last run | [What gets copied](#what-gets-copied) |
| See each run above the prompt and in the footer while it goes | [The badge and band](#the-badge-and-band) |
| See every workhorse's load and the runs going on it, from any session | [Seeing every host](#seeing-every-host) |
| Tell Claude when to offload, and which hosts it has | [The offload policy and the skill](#the-offload-policy-and-the-skill) |
| Give each workhorse the tools you list, and check they still match | [Provisioning](#provisioning) |
| Keep the hosts file, the tools file and the sudo helper somewhere else | [Configuration](#configuration) |

[TESTING.md](TESTING.md) covers the checks that need no workhorse and the end-to-end check against
one.

### Running a job

`wh [host[,host...]] [--timeout <limit>] -- <command...>` runs from anywhere inside a git repository. The
command runs in the same subfolder of the copy. Bound every job with `--timeout`, in seconds,
minutes or hours, up to a week (`168h`):

```bash
wh --timeout 30m -- pnpm test          # a free host, by load
wh alpha --timeout 20m -- cargo test   # a named host
wh alpha,beta --timeout 20m -- make    # the least busy of these
```

The exit code is the command's. Past its limit, `wh` stops the job and everything it started
(`SIGTERM`, then `SIGKILL` 10 seconds later) and exits 124, as `gtimeout` does. The lock on the
host's copy goes only after that, and a job with a limit stops the same way if a signal ends the
shell running it on the host first. The host needs no
`gtimeout`. Exit 3 with `BLOCKED` on stderr means the command did not run, and the message says
why. Exit 2 with a usage or hosts-file message from `wh` on stderr is a usage error, an unknown host, or a
missing or bad hosts file; without one, the command itself exited 2 (`make` exits 2 when a build
fails).

### Stopping a run

`wh ps` lists the runs going from this machine, one a line: the run's number, its host, how long it
has run, its repository and its command. `wh stop <run>` ends one: the job and everything it
started stop on the host, the copy's lock goes, and that run's `wh` exits 143. A run stopped while
it still copies leaves a partial copy, which the next run completes.

`Ctrl-C` on a run's `wh`, or closing its terminal, stops the job on the host the same way, and `wh`
exits 130 or 129. The run log records each of these as `stopped` once the host confirms the job
stopped, or as `stop-unconfirmed` when the host did not answer or this run's lock there is stale (a
lock left from before the host restarted counts as stopped, since no job of it can run).
`wh stop` reads that end: it exits 0 when the job stopped, or the run had already ended, and exits 1
when the job may still be running on the host. The band's Stop button runs `wh stop`.

When the connection to the host drops while the job runs, `wh` stops the job on the host before it
exits 255, ssh's code for a dropped connection. The run log records `lost-stopped` when it stopped
the job, and `lost` when the host did not answer, so the job may still be running. A command's own
exit 255 comes back unchanged.

### Seeing every host

`wh hosts` asks every host at once for its 1-minute load and the runs going there, and prints a line
per host in the hosts file's order, then a line per run:

```
cayde  load 0.10 of 6 cores, idle
xur    load 2.58 of 6 cores, 2 runs
       3875  ~/house/.claude/worktrees/ai-batch  since 15:53  gtimeout 45m make test
       from other-mac pid 412 since 2026-11-26 15:53:42: make test
eris   unreachable
```

A run is a lock in the host's `~/work` whose job runs in a live process, or one under an hour old
that is still copying. A stale lock is not a run: its process has ended, the host has restarted since
the run took it, or it has no process and is over an hour old, though a run still making a large first copy can hold such a lock. A run this machine started leads with the number `wh stop` takes and the folder it
started from. A run from another machine names that machine and its pid there. A host that does not
answer within 5 seconds is unreachable, and a host whose answer is not a probe's shows that answer.
`wh hosts --json` prints one JSON object per host instead, which the [workhorses pane](#the-badge-and-band)
reads. Both strip control characters from what a host sends, so it prints as plain text.

`wh hosts` exits 0 when hosts are unreachable, since the report says so. It exits 2 on any argument
other than `--json`, and on a missing or bad hosts file.

### Choosing a host

With no host named, `wh` asks every host at once for its 1-minute load and physical core count (on
Linux, the cores `lscpu` lists, not their hyperthreads), the runs going there and whether it holds
the repository's copy. Among the hosts whose load is below their core count, it ranks each by its load
plus its runs going, per core, since the 1-minute load lags a run that just started. A run counts
while its process lives on the host, so a stale lock does not. A host that holds
the copy, and so its installed dependencies, wins while that figure is under half; past it the least
busy host wins, so work spreads instead of piling onto one host. It skips a host whose copy another
run holds, so two runs of one repository go to two hosts. It also skips a host whose lock on the copy
is stale, and names it with the reason and the command that removes it. Ties go to the first in the hosts file. A host that has not
answered within 2 seconds counts as unreachable.

Name more than one host, comma-separated, when only some can run the job: `wh alpha,beta -- make` picks
among those by the same rules, ties still going to the first in the hosts file, never the first
named. When none of them is free, it ends `BLOCKED: none of alpha, beta is free:` with each host's
reason. One named host runs the job there whatever its load.

### What gets copied

Each host keeps one copy per repository under `~/work/<repo>-<hash of the local path>/`. A run
locks it, copies `.git`, patches the working tree, then runs the command:

- The first run compares every file's contents.
- Later runs patch only the paths Watchman saw change on your machine, plus the paths the last job
  changed in the copy. When Watchman is missing or has restarted, `wh` says `full walk:` and
  compares every file's size and modification time instead.
- `node_modules/`, `target/`, `.venv/`, `venv/`, `Library/`, `.build/`, `.gradle/`,
  `DerivedData/`, `__pycache__/`, `.DS_Store` and `.cs/` never cross. Install dependencies on the
  host once (`wh --timeout 20m -- pnpm install --frozen-lockfile`) and they stay between runs.
- Git in the copy has your commits, branch and index. A linked worktree's copy is an ordinary
  repository holding the worktree's branch and index.
- `wh` refuses a first copy of over 1 GB that would cross Tailscale, counting `.git` and every file it
  sends but nothing under the names above. The limit also applies when the Mac reaches the host's
  LAN address through a Tailscale subnet router. In that case the message names the interface.
  Make the copy from a network that reaches the host directly, or set
  `WORKHORSES_TAILSCALE_FIRST_COPY_MB` to another limit in MB, a whole number from 1 to
  9999999.

### The badge and band

![Claude Code runs wh in bash mode: the band above the prompt names the run and its time, and the footer badge counts the copy, then spins while the job runs](assets/claude-band.svg)

Every run writes a start, a synced and an end line to `~/.local/state/workhorse/runs.jsonl`. When
Claude Code runs `wh`, the start line also names its session, from `CLAUDE_CODE_SESSION_ID`. The
mod reads that log and shows the runs started from the session's folder:

- The green footer badge names the host and counts the copy, its arrows swapping while the copy
  syncs (`wh ⇄ alpha 0:42`), then a spinner takes their place while the job runs (`wh ⠋ alpha 0:43`).
- The band above the prompt has a row per run (`↗ workhorses │ alpha · 0:43 · demo · pnpm test [ Stop ]`),
  at most three, then a count of the rest. The time reads `copying 0:02` while the copy runs. Stop
  runs `wh stop` for that run; click it, or press ctrl+x tab to reach it and enter to press it. A
  stop that fails says why in a toast.
- A run that took over 2 minutes, ended `BLOCKED` (no workhorse free included), or ended with its job
  in doubt or stopped after a dropped connection (`stop-unconfirmed`, `lost`, `lost-stopped`) ends with
  a toast.
- `/workhorses` opens a pane with every host's load and the runs going on it, from `wh hosts --json`.
  A run this machine started shows the folder it started from and has a Stop button that runs
  `wh stop`. A run this Claude Code session started comes first, marked `this session`; the mark
  goes by session id, so another session's run from the same folder never gets it. The pane asks again when it opens, when you press Refresh, and about once a minute while
  the pane is on screen, not a tab behind another pane. Nothing opens it unasked.

The mod makes no network calls of its own and writes no files. Only its Stop buttons and the
`/workhorses` pane run `wh`, which reaches the hosts over ssh; with the pane closed or behind another
pane, the mod runs no `wh hosts`. It reads the log once a second. While it shows a
run, it runs `ps -o pid=,command= -p <pids>` every 15 seconds and drops a run whose `mirror.sh` has
gone without writing its end line. A run it saw going gets a toast that says so.

Both animations are real runs on one workhorse, named `alpha` in them. In the second one, Claude Code
runs `wh` as a bash-mode command. [The capture scripts and raw frames](assets/capture/README.md) show
how to make them again.

### The offload policy and the skill

At the start of every session, a hook gives Claude the offload policy: when to offload, when to stay
local, a table of your hosts with their ssh target, architecture, cores and RAM, and the tools each
host had at its last sync. It lists the tools every host has once, then what each host has on its own,
with its macOS or Linux release and sync date. Each recipe gets one line. For apt, brew and port,
the startup view lists package names and marks missing packages. Other recipes keep their versions: `- mise: node 24.22.3 26.13.1, go 1.27.4`. It counts the apt packages whose name starts with
`lib` as libraries and names only the missing ones. The hook reads only files on your machine; it never
contacts a host. With no hosts file, or one it cannot use, it says so in one line instead.

The list comes from the record `sync.sh status` stores, so a host never synced has none, and a host
whose tools lines changed since its last sync shows as out of date. A host writes its own record,
and any job on it can change it, so the hook passes on only lines shaped as a tool name and its
version under a recipe shaped as a recipe name, presents them as data, and counts the rest. A
recipe's line stops at 2000 characters and a host's recipe lines at 6000. A separate line counts the omitted recipes.
`sync.sh status` marks the end of a run's log as the host's text, and `sync.sh diff` shows a host's
lines in the same shape. For what no record shows (no code signing, a tool that needs a license),
write `~/.config/workhorses/notes`. The plain policy includes the complete notes. The SessionStart hook installed for Claude Code, Cursor, VS Code,
Grok Build and Kimi Code limits its JSON to 8,500 bytes. When needed, their hook drops the tool lists first and the
notes next. A notice above the host table names the omissions and gives the full-policy command. From the plugin directory, run `bash scripts/policy.sh --full` for all validated
tool versions and the complete notes. The last sync records also remain in the manifests directory
named in the policy. The `workhorse` skill
covers how to run `wh` well: exit codes, first runs, git in the copy, and the steps for adding a tool.

### Provisioning

`wh` needs nothing on a workhorse beyond Remote Login. Everything else is opt-in: the tools file
says what each host gets, and host options change how the Mac runs. `provision/sync.sh` copies the
recipes and options a host needs and runs them there, detached:

```bash
bash provision/sync.sh             # every host; or name some
bash provision/sync.sh status      # how each host's last run ended; stores its record
bash provision/sync.sh diff        # compare the hosts, tools line by tools line
```

Before it contacts any host, `sync.sh` checks the hosts file, the tools file and every recipe it
names. A run stops at the first step that fails, and `status` names that step and its exit code.
A recipe's step fails when its install exits non-zero, or when its probe, run after the install,
exits non-zero or still prints a `missing` line, as it does when an earlier run cut short left a tool
that does not run.
`status` says whether a host's sync is `running` (with its pid), has ended (how, and where it
stopped), was never synced, or has `crashed`. A lock reads as crashed when its run's process no
longer runs, the host rebooted since the run started, or no run started under a lock over an hour old.
`status` then says why and prints the command that removes the lock, and a sync of that host refuses
to start until you remove it; nothing removes it on its own. A lock left by an older version records
no pid and reads as `running`. Stopping `sync.sh` while it holds a lock and has not started the run
frees the lock. `sync.sh diff` names a host whose sync holds its lock, since a tool it installs
can read as missing or different.
`status` reports every host and exits non-zero when one does not answer or its last run failed.
On the host, the run adds one line, marked `# workhorses`, which loads the `PATH` the recipes
set, to the file the login shell reads for an ssh command: the end of `~/.zshenv` on a Mac or for
zsh on Linux, and the top of `~/.bashrc` for bash on Linux. The rest of that file stays untouched.
Removing a line from the tools file, or an option from a host, undoes nothing on the host.

#### The tools file

`~/.config/workhorses/tools` has one recipe per line, then its arguments, then any filters.
Lines run in file order, so a line goes after the one it needs. It starts empty;
[examples/tools](examples/tools) shows the shape.

```text
command-line-tools
macports
port cmake ninja ripgrep nodejs24 npm11
npm pnpm @openai/codex
mise node@26
dotnet 10.0 @arch=x86_64
unity 6000.3.28f1 8f082d2fe476 android ios webgl @hosts=alpha
```

- `@arch=x86_64` or `@arch=arm64` gives the line only to hosts of that architecture,
  `@os=macos` or `@os=linux` only to hosts that run that system, and `@hosts=alpha,beta` only to
  those hosts. A host must match every filter on the line. The hosts file does not say which system
  a host runs: `sync.sh` asks each host before it sends anything, and `diff` and the policy read it
  from the host's record.
- Arguments are letters, digits and `@._/+-`, and never start with `-`. A recipe gets them as its
  arguments, never as shell text.
- `sync.sh diff` compares each line only among the hosts it targets. The Command Line Tools follow the
  macOS release, so it compares them only among hosts on the same major release.

| Recipe | Arguments | Installs |
| --- | --- | --- |
| `command-line-tools` | none | Apple's Command Line Tools: git, clang, make (sudo; macOS only) |
| `macports` | none | MacPorts for macOS 15 or 27; every sync upgrades outdated ports (sudo; macOS only) |
| `port` | port names | MacPorts ports (sudo; needs `macports` first; macOS only) |
| `npm` | package names, `pkg@version` to pin | global npm packages under `~/.local`, at their latest unless pinned |
| `mise` | `tool@version` | runtimes through mise; run one with `mise exec node@26 -- <command>`. On Linux it installs mise itself, and the line's versions become the defaults on the `PATH`, the first of a tool first |
| `uv` | none | uv |
| `uv-tool` | package names | Python command-line tools through uv |
| `gem` | gem names | gems and their commands, under `~/.local` |
| `claude` | none | Claude Code, updated on every sync |
| `rustup` | none | Rust |
| `dotnet` | a channel, `10.0` | the .NET SDK |
| `bun` | none | bun, upgraded on every sync |
| `opencode` | none | opencode, upgraded on every sync |
| `chrome-for-testing` | none | Chrome for Testing, with `CHROME_BIN` pointing at it |
| `bundletool` | a version | Google's bundletool |
| `macos-harness` | none | macos-harness and its skill for Claude on the host (macOS only) |
| `unity` | version, changeset, modules | Unity Hub, the `unity` command and one editor, without a license (macOS only) |
| `apt` | exact package names, none ending in `-` or `+` | Debian and Ubuntu packages, after `apt-get update`; give its line `@os=linux` (sudo) |

A recipe that needs another one fails with a message naming it, such as `port needs MacPorts: list
macports before it`. Every recipe but the `apt` one runs on a Mac, and every one but the five marked
macOS only runs on Linux. A line for one of those five that reaches a Linux host stops `sync.sh`
before it asks for the sudo password or takes the host's lock, with a message that names the
`@os=macos` filter the line lacks.

#### Your own recipes

A recipe is an executable that answers `install [args]` and `probe [args]`. `probe` prints one
`<name> <version>` line per tool, or `<name> missing` for a tool it does not find, and exits 0. A probe that exits
non-zero fails its step. Its install skips on the test its probe makes, so a probe that finds the tool
means the install has nothing left to do. The policy's tool list shows those lines on the
recipe's line, each without the recipe's name and the space or dash after it. Put yours in
`~/.config/workhorses/recipes/<name>`. The name is lower-case letters, digits and
dashes, and may not be a built-in recipe's name. `sync.sh` refuses a recipe unless you own it, its
folder and the config folder, and nobody else can write any of them, because it runs on every host
its line targets. A recipe that runs `sudo -A` says so with the line `# needs: sudo` near its top;
only those recipes get the sudo password. A recipe that runs only on macOS says so with the line
`# os: macos` there, and `sync.sh` refuses its line on a Linux host. `sync.sh` copies only the `recipes` folder's named files
to a host, never the config folder itself.

#### Host options

Host options go at the end of a host's line in the hosts file. Each one changes the Mac for every
user of it, so give them only to a Mac that exists to run jobs. None is on by default. They are macOS
settings: `sync.sh` refuses a Linux host whose line has any, naming them, before anything runs.

| Option | What it does | Sudo |
| --- | --- | --- |
| `no-sleep` | Never sleep, restart after a power cut, wake on LAN | yes |
| `no-spotlight` | Spotlight indexing off on every volume | yes |
| `maxfiles` | Open-file limit 65536/200000, now and at every boot | yes |
| `wifi-off` | Wi-Fi off while Ethernet is up, so traffic takes the cable | yes |
| `git-identity` | A neutral global git name and email, for test suites that commit | no |
| `key-only-ssh` | ssh logins by key only | yes |
| `firewall` | macOS firewall on, in stealth mode, signed apps allowed | yes |
| `headless` | No screensaver and no Siri | no |
| `dock` | A Dock with Terminal, Activity Monitor and System Settings; keeps a backup | no |
| `wallpaper=<name>` | A solid wallpaper from Solid Colors, `_` for each space: `wallpaper=Turquoise_Green` | no |
| `screensharing` | Lets the workhorse user in over Screen Sharing | yes |
| `tailscale` | Installs Tailscale; you log in on the Mac's screen | yes |
| `autologin` | Logs the workhorse user in at boot | yes |

> [!WARNING]
> `autologin` stores the workhorse user's password in `/etc/kcpassword`. The file is root-only,
> but macOS keeps the password there in a reversible form, not encrypted.

#### The sudo password

`sync.sh` asks for a host's sudo password only when one of its options, or a recipe on one of its
lines, needs it. A host with neither syncs without one. It runs your helper,
`~/.config/workhorses/sudo-password`, with the host name as its one argument and reads the
password from its output. The helper must be a file you own that only you can write; the plugin
never runs its output as shell text. [examples/sudo-password](examples/sudo-password) reads it from
the login keychain. The password reaches the host on the ssh session's stdin, never in an
environment variable, a command line or a file. On the host, the shell that loads the env snippets
for each step never holds it, and a step that does not declare sudo never gets it. A step that does
gets it in its environment as `SUDO_PW`, and so does every program that step starts. The login shell
that starts the run reads its startup file while the password waits on its stdin, and any process
running as the workhorse user can change what the sudo steps run, so the password is only as safe as
that account.

### Linux and WSL hosts

A Linux host needs sshd, your ssh key, `rsync`, `git` for git commands, and bash or zsh as the
workhorse user's login shell. `wh` uses the system's `find`, `awk`, `sort` and `lscpu`, which
Debian and Ubuntu ship. `/workhorses:setup` probes it like a Mac: `uname -m` for the
architecture (`aarch64` becomes `arm64`), physical cores from `lscpu`, and RAM from `MemTotal`,
rounded to the nearest GB. Host options are Mac settings and do not apply. The `apt` recipe
installs packages with `sudo`, so a host without sudo takes only lines that need none.

Ubuntu's packages stand in for MacPorts where their version is current enough. Where apt has a tool
only in an old version, under another command name (`fdfind`, `batcat`) or not at all, a `mise` line
brings it: node, go, Ruby, `gh`, `fd`, `bat`, `yq` and the like. On Linux the `mise` recipe installs
mise into `~/.local/bin` and keeps it current, and its line's versions become mise's global ones,
on the `PATH` through mise's shims, so `mise node@24 node@26` makes `node` the 24 and leaves 26 to
`mise exec node@26 --`. The shims come ahead of the system's folders, so mise's versions win over
apt's, but behind `~/.local/bin` and the folders of recipes whose names sort after `mise`, such as
rustup's `~/.cargo/bin`. The recipes need a few packages before them on Linux:

- `curl`, which a minimal Ubuntu lacks, for the `mise`, `uv`, `claude`, `rustup`, `dotnet`, `bun`,
  `opencode` and `bundletool` recipes, which download with it; put it on the `apt` line, listed first.
- `build-essential` for the C compiler and linker that Rust, gems with native code and mise's Ruby use.
- `unzip` for `bun`'s installer, and `libatomic1` for node 26.
- Chrome for Testing's libraries for `chrome-for-testing`; on Ubuntu 24.04: `libnss3`,
  `libatk-bridge2.0-0t64`, `libcups2t64`, `libxkbcommon0`, `libxcomposite1`, `libxdamage1`,
  `libxfixes3`, `libxrandr2`, `libgbm1`, `libpango-1.0-0`, `libcairo2` and `libasound2t64`.
- A `java` for `bundletool`, such as `openjdk-21-jdk-headless`.

A Windows PC serves through WSL2, with Ubuntu say:

- Run sshd inside WSL and make it reachable from your machine, then put the route in
  `~/.ssh/config` and name that alias in the hosts file.
- The work copies live under `~/work` in the WSL user's home, on the Linux filesystem. Never move
  them to `/mnt/c`, the Windows drive, or link them there. Microsoft's WSL guidance keeps the files
  Linux tools work on in the Linux filesystem, for speed.
- The probe reports the cores and memory WSL2 has, which Windows sets for the WSL2 machine.
- Use WSL's mirrored networking: `wh` refuses a first copy of over 1 GB through Tailscale by the
  server address of the ssh connection inside WSL, which in the default network address translation
  (NAT) mode is WSL's own address, never Tailscale's.

### Configuration

| Setting | Where |
| --- | --- |
| Hosts and host options | `~/.config/workhorses/hosts` |
| What each host gets | `~/.config/workhorses/tools` |
| Your own recipes | `~/.config/workhorses/recipes/` |
| Facts for Claude that no record shows | `~/.config/workhorses/notes` |
| Sudo passwords, for `sync.sh` | `~/.config/workhorses/sudo-password`, an executable |
| Another config folder | `WORKHORSES_CONFIG_DIR`, read by `wh`, `sync.sh` and the policy |
| The largest first copy `wh` sends through Tailscale | `WORKHORSES_TAILSCALE_FIRST_COPY_MB`, in MB, 1024 by default |
| Each host's last record | `~/.local/state/workhorses/manifests/<host>`, or `WORKHORSES_STATE_DIR` |

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `wh` exits 2 with "no hosts file" | Run `/workhorses:setup` or write `~/.config/workhorses/hosts`, as in [First run](#first-run). For a bad line, the error names the file and the line number. |
| `wh: command not found` in your own terminal | Claude Code puts the plugin's `bin/` on the path of the commands Claude runs, not on your shell's. Call `bin/wh` in the installed plugin by its full path, or link it into a folder on your `PATH`. |
| `wh` exits 124 | The job ran past `--timeout`. Give it a longer limit, or split it. |
| `BLOCKED: no workhorse is free`, or `none of alpha, beta is free` after a list of hosts | The message lists each host's reason. Every host, or every host listed, is at its core count or unreachable; run the job locally. After a list, run it locally only when this machine can run the job too; otherwise wait and retry. |
| `... is in use by another run ...` | Another run holds that copy's lock: its job runs, or that run still copies. The owner it names, `<machine> pid <number>`, gives the number `wh stop <number>` takes on that machine. |
| `BLOCKED: the job did not start: ...` | Someone removed the lock this run took on the host's copy while the run still copied, and the job did not run. When the message names another run's lock, that run took the copy since; `wh` leaves that lock alone. Run the job again. |
| `... .lock is stale (...)` | The message says why. When the lock's process has ended, its pid file holds no process id, or the host restarted, the run that took it has ended: run the `ssh ... 'rm -r ...'` command the message gives. When the lock holds no pid and is over an hour old, its run may still be copying: run the command only once `wh ps` on the machine its owner names no longer lists that run. `wh` never removes a stale lock itself. |
| A run must stop | `wh ps` lists the runs going; `wh stop <run>` ends one, its job on the host included. |
| Every run says `full walk:` | Watchman is not installed, or it restarted since the last run. |
| `git` fails on a new host | macOS's `git` stays a stub until the Command Line Tools arrive. Add the `command-line-tools` line. On Linux, install `git` (`apt git @os=linux`). |
| `sync.sh` says a host "runs Linux, where host options do not apply" | Remove the options it names from that host's line in the hosts file. |
| `sync.sh` or a run stops with `<recipe> runs only on macOS` | That recipe's line reached a Linux host. Give it `@os=macos`. |
| `sync.sh status` says `stopped at <step>` | That recipe or option failed; the lines under it are the end of the host's `~/workhorse/run.log`. A recipe that needs another names it there. |
| `sync.sh status` says `crashed`, or a sync says "the last sync crashed" | A kill or a reboot ended its run mid-sync. Check nothing installs there, run the `ssh <host> 'rm -r ~/workhorse.lock'` it prints, then sync again. |
| `sync.sh` says "no sudo password" | The line above it says why: the helper is missing, not executable, writable by others, failed, or printed nothing. |
