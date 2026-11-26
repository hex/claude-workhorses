# Testing

## Checks that need no workhorse

```bash
bash tests/run.sh
```

It runs, in order:

| Check | What it proves |
| --- | --- |
| `tests/pick-check.sh` | `wh` reads a Mac's and a Linux host's probe answer into load and physical cores, and picks the right host from given probe answers. |
| `tests/route-check.sh` | A Tailscale address counts toward the first-copy guard. The guard ignores loopback. On a Mac with a Tailscale subnet route, the guard names the address and interface. Other machines skip that case. |
| `tests/limits-check.sh` | The 2 s probe bound returns at once when a command answers and stops one that hangs; `wh --timeout` stops a job and its children past the limit with exit 124, a child that ignores `SIGTERM` included, stops the job when the shell running it dies by signal, stops a job with no limit too when `wh stop` sends that shell `SIGTERM`, leaves a job inside it alone, and refuses a bad limit or one over a week. |
| `tests/hosts-check.sh` | The hosts file loads in order and every bad value or host option fails with its line, a host named `ps` or `stop` included, a line in the format before 2026.11.2 with a message that says so; the sudo-password helper gets the host name as its one argument and fails when others can write it; `scripts/probe-host.sh` turns a host's answer into a hosts line, a Linux `aarch64` written as `arm64`, and refuses a bad target before ssh runs. |
| `tests/tools-check.sh` | `load_tools` refuses a bad recipe, argument or filter, each host gets the lines its filters select (`@os` by the OS recorded for the host; a host whose OS is unknown gets no `@os` line, and stderr names it), user recipes and their folders must be the user's alone, a recipe may not be a symlink or a folder, and none may take a built-in's name, and a host needs the sudo password only when an option or a recipe on its lines does. |
| `tests/apply-check.sh` | What `sync.sh` stages for a host (never the config folder), how `provision/host/apply.sh` runs it with `HOME` in a throwaway folder (arguments as argv, sudo only for recipes that declare it, a stop at the first failure, a step that reads stdin or an env snippet that reads an unset variable breaking nothing, a snippet that exits stopping the run at its env step, `apply.sh start` returning while the run goes on, one line added to `~/.zshenv` no matter how often it runs, or on Linux with bash to the top of `~/.bashrc`, above its interactive guard, and a login shell other than bash or zsh stopping the run at its env step), that the sudo password travels only on the stdin of the ssh that starts the run and that an env snippet planted on the host can read neither it nor a descriptor that could carry it, that a host option gets the password only when it needs sudo, that a run that fails to start frees the lock, that `sync.sh` asks each host's OS before any password, lock or stage, stages the `apt` line only for a Linux host and refuses host options on one, and a line for a macOS-only recipe on one, that a bad file stops `sync.sh` before any ssh, that `status` reports every host, marks the end of `run.log` as host text and stores a finished run's manifest, and that `diff` compares each line only among its hosts, the OS read from each manifest, shows host text only as probe lines, and fails on a tool a host reports missing. |
| `tests/apt-check.sh` | The `apt` recipe, run against stand-ins for `sudo`, `apt-get`, `apt-cache` and `dpkg-query`, refuses a name that ends in `-` or `+` before `apt-get` runs and a name no package has exactly before the install, and installs waiting up to 5 minutes for apt's lock and keeping conffiles edited on the host; its probe prints one line a package, one installed for two architectures included. |
| `tests/recipes-check.sh` | The macOS-only recipes (`command-line-tools`, `macports`, `port`, `macos-harness`, `unity`), run with a stand-in `uname` that says Linux, stop with a message naming `@os=macos` before they run any command. On a Mac, `mise` only installs the line's versions; on Linux it installs mise into `~/.local/bin` when no mise is on the `PATH` (and updates that copy on later runs), and makes the line's versions the global ones. The `env.sh` that `apply.sh` builds puts mise's shims ahead of the system's folders, behind `~/.local/bin` and the folders of snippets that sort after `mise`'s, such as rustup's `~/.cargo/bin`. `mise`'s probe prints each tool once, even when a line names two of its versions. `uv`'s probe prints one release the same from a Mac and a Linux host, dropping everything after the version. |
| `tests/policy-check.sh` | The session-start policy renders the host table and each host's tools from stored manifests (one line per recipe, apt libraries counted and named only when missing; only lines shaped as a tool and its version under a recipe shaped as a recipe name, the rest counted; header values in their own shapes, a Linux release included; capped; stale hosts named, with `@os` lines matched to each record's OS), appends the notes file, names this install's `wh` and scripts, runs no ssh, and says so in one line when the hosts or tools file is missing or bad; Antigravity's hook carries the whole policy in its JSON step. Copilot returns the same policy in `additionalContext`, or the error if the policy script fails. Four hosts with 26 packages each and 1.65 KB of notes must fit in 8,500 bytes of session-start JSON with all notes intact. Oversize fixtures check that the hook keeps the host table, offload rules and full-policy command, drops tools before notes, and leaves the plain policy complete. |
| `tests/manifests-check.sh` | The Claude Code, Codex, GitHub Copilot CLI, Antigravity, Kimi Code and npm manifests name the same version. Copilot's manifest points to a version 1 hook file with a `sessionStart` command. |
| `claude plugin test .` | The workhorse-runs mod's tests, `mods/workhorse-runs/hooks/register.test.tsx`. |

CI runs the same script on Ubuntu and macOS, the macOS job under `/bin/bash` 3.2.

No check runs a recipe's `install` or a host option on the machine itself: they change the host they
run on. `apt-check` and `recipes-check` run recipes with stand-ins for the tools they call. Run each recipe's
`probe` by hand when you change it; probes only read.

## Check the npx installs

```bash
python3 tests/npx-check.py
```

The check needs network access for npx, Node.js, Python 3, jq, and the Grok and Copilot CLIs on
`PATH`. It runs `plugins@1.3.9` against this checkout, with a fresh home for each target and one
fictional host. To check a single target, pass its ID, for example `python3 tests/npx-check.py cursor`.

It follows each install registration to the skill on disk. For Claude Code it also checks the mod
entry point. For Claude Code, Codex, Cursor, Copilot CLI, VS Code and Kimi it runs the installed hook
command and compares the context field or stdout with the installed policy. For Grok it checks
the native component inventory. Grok’s npx install carries `hooks/hooks.json` and runs the same
8,500-byte SessionStart hook as Claude Code, Cursor, VS Code and Kimi. Grok leaves its output out of
model context. For Kimi it also checks that the manifest registers the startup skill. The check removes the
temporary homes and npm cache on exit. It runs separately from `tests/run.sh` and does not open
an agent session.

Separate live checks covered Claude Code and interactive Copilot CLI. Grok Build listed the
workhorse skill in a live session. The Codex manifest and hook file are unchanged since 2026.11.13. The policy
text Codex receives has changed. The recorder in `tests/agents-check.sh` checked the new text.
A live Codex session with that text is still unverified. For Cursor, VS Code and Kimi, the checks cover the installed files and hook commands. Cursor hit a usage limit,
VS Code required an editor window, and the Kimi account was suspended.

## The policy in each agent

```bash
bash tests/agents-check.sh
```

It runs Claude Code, Codex, pi and OpenCode, each with this checkout as its plugin, in throwaway
config folders, pointed at a local server that records each request and answers it with an error,
so no request reaches a model provider (an agent may still fetch its own settings or plugins). Each
passes when a request it sent holds a token found only in the notes of the check's own config, and
the workhorse skill. An agent that is not installed prints a `skip:` line, and the check fails when
none is. Codex runs with `--dangerously-bypass-hook-trust` in its throwaway `CODEX_HOME`; your own
Codex still asks you to trust the hook in `/hooks`. The check does not run Antigravity;
`policy-check` checks its hook's output instead.

## Type check

The mod's types come from `/plugin-types`, which writes `.claude/types/` at the repo root
(ignored by git). Then:

```bash
npx -y -p typescript tsc --noEmit -p mods/workhorse-runs
```

## End to end, against a workhorse

```bash
gtimeout 15m bash tests/wh-check.sh alpha
```

It runs `wh` against the named host, a Mac or a Linux host, over 40 kinds of change: edits, restores to older times,
executable bits, folders, renames, symlinks, edits the job made in the copy, `node_modules` left to
each side, a forgotten Watchman watch, exit codes, the run log, `wh stop` on a run going, and git
in a repository and in a linked worktree. It then makes three fresh repositories with 3 MB of files each and a Tailscale
first-copy limit of 2 MB: through the host's own Tailscale address, read on the host and named in a
hosts file of the check's own, `wh` blocks the first and runs the second, whose bulk sits under
`node_modules/`; through the hosts file's own target the third runs. A host with no Tailscale
address, or one ssh cannot reach on it, prints a `skip:` line for the first two, and a hosts file
target that already goes through Tailscale one for the third. The check removes every copy it made
under `~/work`. It works in throwaway folders and exits 1 on the first mismatch. Point it at a test
hosts file with `WORKHORSES_CONFIG_DIR` to keep your own untouched.

## Upgrading a provisioned workhorse

For a host the scripts before recipes provisioned (`setup.sh`, `tools.sh`, `unity.sh`), this
check compares the host before and after the new `sync.sh`, read both times by the same old
`manifest.sh`. Run it on one host first. `alpha` and `alpha-mini` stand for its name and ssh target.

1. Snapshot the host with the old scripts, which read `CLAUDE_WORKHORSES_CONFIG_DIR`, right after an old sync, so the installers' own updates
   move as little as possible between the two snapshots:

   ```bash
   old=$(git rev-list -n 1 HEAD -- provision/setup.sh)^
   git worktree add /tmp/wh-old "$old"
   git show "$old:provision/manifest.sh" >/tmp/old-manifest.sh
   CLAUDE_WORKHORSES_CONFIG_DIR=<folder with the old-format hosts file> bash /tmp/wh-old/provision/sync.sh alpha
   CLAUDE_WORKHORSES_CONFIG_DIR=<same folder> bash /tmp/wh-old/provision/sync.sh status alpha   # until exit=0
   ssh alpha-mini 'zsh -s' </tmp/old-manifest.sh >/tmp/alpha-before.txt
   ```

2. Sync with the new code. In a second config folder, write the hosts file in the new format, with
   the host options that match the old profile, and a tools file whose lines cover every step of the
   old `setup.sh`, `tools.sh` and `unity.sh`:

   ```bash
   WORKHORSES_CONFIG_DIR=<new folder> bash provision/sync.sh alpha
   WORKHORSES_CONFIG_DIR=<new folder> bash provision/sync.sh status alpha   # until exit=0
   ```

3. Compare, with the same old `manifest.sh`:

   ```bash
   ssh alpha-mini 'zsh -s' </tmp/old-manifest.sh >/tmp/alpha-after.txt
   diff /tmp/alpha-before.txt /tmp/alpha-after.txt
   git worktree remove /tmp/wh-old
   ```

   Lines that may differ without a fault are the tools that update themselves on every sync:
   `claude`, `bun`, `opencode`, npm packages installed at `@latest`, Chrome for Testing, and ports
   that MacPorts upgraded between the two snapshots. Any other line that differs is a step the tools file or the
   options missed.

4. To exercise the install path, where every recipe installs instead of finding its tool present,
   sync a fresh user account on a host with a tools file of per-user recipes (`uv`, `npm`,
   `rustup`, `bun`, `claude`), then run `bash provision/sync.sh status` and `diff`.
