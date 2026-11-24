# Changelog

This file lists the notable changes to claude-workhorses. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
`YYYY.M.BUILD`, where `BUILD` resets each month.

## 2026.11.1

### Added
- `wh [host] -- <command>` runs a command on a workhorse in that host's copy of the current git repository, brought level with your machine first, `.git` included, and exits with the command's exit code. With no host it picks a free one by load per core, preferring a host that already holds the copy. Exit 3 with `BLOCKED` means the command did not run.
- The hosts come from `~/.config/claude-workhorses/hosts`, one line per host: name, ssh target, arch, cores, RAM, profile and wallpaper color. `CLAUDE_WORKHORSES_CONFIG_DIR` points the plugin at another folder. The plugin checks every value when it reads the file and names a bad line by its number.
- At session start, Claude reads a policy saying when to offload a job and when to keep it local, with a table of your hosts.
- The `workhorse` skill: how to run `wh`, its exit codes, first runs and git in the copy.
- The workhorse-runs mod: a green `wh` badge in the prompt footer while a run goes, a line per run above the prompt (at most three, then a count), and a toast when a long or `BLOCKED` run ends.
- `provision/sync.sh` sets up every workhorse with the same tools, in a dedicated or a shared profile, and `sync.sh diff` compares them. It reads each host's sudo password from a helper you own, `~/.config/claude-workhorses/sudo-password`, called with the host name.
