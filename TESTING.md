# Testing

## Checks that need no workhorse

```bash
bash tests/run.sh
```

It runs, in order:

| Check | What it proves |
| --- | --- |
| `tests/pick-check.sh` | `wh` picks the right host from given probe answers. |
| `tests/hosts-check.sh` | The hosts file loads in order and every bad value fails with its line; the sudo-password helper gets the host name as its one argument and fails when others can write it. |
| `tests/policy-check.sh` | The session-start policy renders the host table, names this install's scripts, and says so in one line when the hosts file is missing or bad. |
| `claude plugin test .` | The workhorse-runs mod's tests, `mods/workhorse-runs/hooks/register.test.tsx`. |

CI runs the same script on Ubuntu and macOS, the macOS job under `/bin/bash` 3.2.

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
