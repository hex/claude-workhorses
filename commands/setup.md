---
description: Add Macs or Linux hosts as workhorses - probe each ssh target into a hosts-file line, then run a first wh job with nothing installed
argument-hint: <ssh target>... (an alias from ~/.ssh/config or user@host)
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/probe-host.sh:*), Bash(mkdir:*), Bash(wh:*), Read, Write, Edit, AskUserQuestion
---

## Context

- Arguments: $ARGUMENTS
- Config folder: `${CLAUDE_WORKHORSES_CONFIG_DIR:-~/.config/claude-workhorses}`

## Your task

Add each ssh target in the arguments to the claude-workhorses hosts file, then prove `wh` reaches it.
This installs nothing on the hosts. With no arguments, ask the user for the ssh targets with
**AskUserQuestion** and stop until they answer.

1. For each target, run:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/probe-host.sh <target>
   ```

   It prints one hosts line, `<name> <target> <arch> <cores> <RAM in GB>`, or fails with the reason.
   A target that fails most often lacks Remote Login or the user's ssh key; report the message and
   leave that target out. Pass a second argument to choose the name when the default clashes with a
   host already in the hosts file or the user asks for another.

2. Read the hosts file if it exists. Show the user the exact lines you would append, and ask with
   **AskUserQuestion** whether to append them. Mention that host options (`no-sleep`, `maxfiles`,
   `autologin` and the rest, listed in the plugin's `examples/hosts`) can go at the end of a line
   later, and that each one changes the Mac for every user of it. Add none unless the user asks, and
   never on a Linux host: they are macOS settings, and `sync.sh` refuses a Linux host that has any.

3. On yes, create the config folder with `mkdir -m 700 -p` when missing, then add the lines at the
   end of the hosts file with Edit, or Write when the file is new. Write no
   tools file: it starts empty, and the workhorse skill adds a line when a job needs a tool.

4. From inside a git repository (the session's folder, or ask for one), run for each new host:

   ```bash
   wh <name> --timeout 2m -- git log -1 --oneline
   ```

   The first run copies the repository. A commit line back means the host works. A host without the
   Command Line Tools fails here, because macOS's `git` stays a stub until someone installs them.
   Then propose the tools line `command-line-tools @hosts=<name>` through the workhorse skill's
   missing-tool steps; it needs the sudo-password helper the README describes. A Linux host without
   `git` fails the same way; propose `apt git @hosts=<name>` there, which also needs sudo on the host.

5. Report each host's line, the `wh` result, and anything left to do.
