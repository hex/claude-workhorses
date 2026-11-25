# Testing

## Checks that need no workhorse

```bash
bash tests/run.sh
```

It runs, in order:

| Check | What it proves |
| --- | --- |
| `tests/pick-check.sh` | `wh` picks the right host from given probe answers. |
| `tests/limits-check.sh` | The 2 s probe bound returns at once when a command answers and stops one that hangs; `wh --timeout` stops a job and its children past the limit with exit 124, a child that ignores `SIGTERM` included, stops the job when the shell running it dies by signal, leaves a job inside it alone, and refuses a bad limit. |
| `tests/hosts-check.sh` | The hosts file loads in order and every bad value or host option fails with its line; the sudo-password helper gets the host name as its one argument and fails when others can write it; `scripts/probe-host.sh` turns a host's answer into a hosts line and refuses a bad target before ssh runs. |
| `tests/tools-check.sh` | `load_tools` refuses a bad recipe, argument or filter, each host gets the lines its filters select, user recipes and their folders must be the user's alone and may not take a built-in's name, and a host needs the sudo password only when an option or a recipe on its lines does. |
| `tests/apply-check.sh` | What `sync.sh` stages for a host (never the config folder), how `provision/host/apply.sh` runs it with `HOME` in a throwaway folder (arguments as argv, sudo only for recipes that declare it, a stop at the first failure, a step that reads stdin or an env snippet that reads an unset variable breaking nothing, one line added to `~/.zshenv` no matter how often it runs), that the sudo password travels only on the stdin of the ssh that starts the run and that an env snippet planted on the host can read neither it nor a descriptor that could carry it, that a host option gets the password only when it needs sudo, that a run that fails to start frees the lock, that a bad file stops `sync.sh` before any ssh, that `status` reports every host, marks the end of `run.log` as host text and stores a finished run's manifest, and that `diff` compares each line only among its hosts, shows host text only as probe lines, and fails on a tool a host reports missing. |
| `tests/policy-check.sh` | The session-start policy renders the host table and each host's tools from stored manifests (only lines shaped as a tool and its version, the rest counted; header values in their own shapes; capped; stale hosts named), appends the notes file, names this install's scripts, runs no ssh, and says so in one line when the hosts or tools file is missing or bad. |
| `claude plugin test .` | The workhorse-runs mod's tests, `mods/workhorse-runs/hooks/register.test.tsx`. |

CI runs the same script on Ubuntu and macOS, the macOS job under `/bin/bash` 3.2.

No check runs a recipe's `install` or a host option: they change the Mac they run on. Run each
recipe's `probe` by hand when you change it; probes only read.

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

It runs `wh` against the named host over 40 kinds of change: edits, restores to older times,
executable bits, folders, renames, symlinks, edits the job made in the copy, `node_modules` left to
each side, a forgotten Watchman watch, exit codes, the run log, and git in a repository and in a
linked worktree. It works in throwaway folders and exits 1 on the first mismatch. Point it at a test
hosts file with `CLAUDE_WORKHORSES_CONFIG_DIR` to keep your own untouched.

## Upgrading a provisioned workhorse

For a host the scripts before recipes provisioned (`setup.sh`, `tools.sh`, `unity.sh`), this
check compares the host before and after the new `sync.sh`, read both times by the same old
`manifest.sh`. Run it on one host first. `alpha` and `alpha-mini` stand for its name and ssh target.

1. Snapshot the host with the old scripts, right after an old sync, so the installers' own updates
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
   CLAUDE_WORKHORSES_CONFIG_DIR=<new folder> bash provision/sync.sh alpha
   CLAUDE_WORKHORSES_CONFIG_DIR=<new folder> bash provision/sync.sh status alpha   # until exit=0
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
