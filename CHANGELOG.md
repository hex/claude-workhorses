# Changelog

This file lists the notable changes to claude-workhorses. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
`YYYY.M.BUILD`, where `BUILD` resets each month.

## Unreleased

### Added
- Linux workhorses, a Windows PC's WSL2 included. `wh` reads a Linux host's 1-minute load from `/proc/loadavg` and its physical cores from `lscpu`, so hyperthreads do not count, and lists its copy with GNU `find` in the same format as on a Mac. `/claude-workhorses:setup` probes a Linux host into a hosts line. The hosts file does not change: `sync.sh` asks each host which system it runs before it sends anything, and the host's record names it (`linux Ubuntu 24.04.5 LTS`).
- Tools lines take `@os=macos` or `@os=linux`. `sync.sh`, `sync.sh diff` and the session-start policy honor it.
- The `apt` recipe installs Debian and Ubuntu packages with `sudo` and probes each with `dpkg-query`.

### Changed
- On a Linux host whose login shell is bash, `sync.sh` puts its env line at the top of `~/.bashrc`, above the stock file's guard for shells that are not interactive, since sshd's bash reads that file for every command. zsh on Linux gets `~/.zshenv` as on a Mac, and any other login shell stops the run at its env step.
- `sync.sh` refuses a Linux host whose hosts line has host options, which are macOS settings, before anything runs.
- A record's probe lines may hold `~`, which Debian versions use.

### Fixed
- A linked worktree's copy on a host could keep the main checkout's `HEAD` when the copy started from the main checkout's and the two `HEAD` files matched in size and second. The worktree's own git files now go by checksum.

## 2026.11.3

### Fixed
- `sync.sh diff` compares the Command Line Tools only among hosts on the same major macOS release, so hosts on different releases no longer fail the diff for a version that follows macOS.

## 2026.11.2

### Changed
- Workhorses get only what you ask for. `wh` needs nothing on a host beyond Remote Login, and `sync.sh` installs the tools listed in `~/.config/claude-workhorses/tools`, one recipe and its arguments per line, with optional `@arch=` and `@hosts=` filters. Built-in recipes cover the Command Line Tools, MacPorts, ports, npm, mise, uv, gems, Claude Code, Rust, .NET, bun, opencode, Chrome for Testing, bundletool, macos-harness and Unity; your own go in `~/.config/claude-workhorses/recipes/`.
- The hosts file drops the profile and color columns, and a line still in the old format fails with a message that says so and points to `examples/hosts`. Host options at the end of a line (`no-sleep`, `maxfiles`, `wallpaper=Turquoise_Green`, `autologin` and the rest) replace what the dedicated profile used to apply. None is on by default.
- `sync.sh` appends one marked line to `~/.zshenv` instead of replacing the file, and sets a git identity only with the `git-identity` option. It asks for a sudo password only when a host's options or recipes need one, sends it on the ssh session's stdin instead of an environment variable, and only those steps get it: the shell that loads env snippets never holds it, and no environment variable carries it past `~/.zshenv`.
- A sync stops at the first failing step, and `sync.sh status` names it, reports every host even when one does not answer, and exits non-zero when a host does not answer or its last run failed. A sync whose run fails to start says so and removes the host's lock. `sync.sh diff` compares each tools line among the hosts it targets.
- The session-start policy lists each host's tools from the record `sync.sh status` stores, and appends `~/.config/claude-workhorses/notes`. Only record lines shaped as a tool and its version reach it, framed as data the host reported, with a count of the lines left out. `sync.sh diff` fails when a host reports a tool missing, even if every host does.
- `wh --timeout 30m -- <command>` bounds a job on the host and exits 124 past the limit. Neither your machine nor a workhorse needs `gtimeout` any more.

### Added
- `/claude-workhorses:setup <ssh target>...` probes each Mac into a hosts line and runs a first `wh` job on it.

## 2026.11.1

### Added
- `wh [host] -- <command>` runs a command on a workhorse in that host's copy of the current git repository, brought level with your machine first, `.git` included, and exits with the command's exit code. With no host it picks a free one by load per core, preferring a host that already holds the copy. Exit 3 with `BLOCKED` means the command did not run.
- The hosts come from `~/.config/claude-workhorses/hosts`, one line per host: name, ssh target, arch, cores, RAM, profile and wallpaper color. `CLAUDE_WORKHORSES_CONFIG_DIR` points the plugin at another folder. The plugin checks every value when it reads the file and names a bad line by its number.
- At session start, Claude reads a policy saying when to offload a job and when to keep it local, with a table of your hosts.
- The `workhorse` skill: how to run `wh`, its exit codes, first runs and git in the copy.
- The workhorse-runs mod: a green `wh` badge in the prompt footer while a run goes, a line per run above the prompt (at most three, then a count), and a toast when a long or `BLOCKED` run ends.
- `provision/sync.sh` sets up every workhorse with the same tools, in a dedicated or a shared profile, and `sync.sh diff` compares them. It reads each host's sudo password from a helper you own, `~/.config/claude-workhorses/sudo-password`, called with the host name.
