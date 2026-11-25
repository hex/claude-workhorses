# Rebuild the README images

Run these from the checkout root against a workhorse you can reach over ssh:

```bash
WH_CAPTURE_SSH_TARGET=me@mini.example.test bash assets/capture/wh-run.sh
WH_CAPTURE_SSH_TARGET=me@mini.example.test bash assets/capture/claude-band.sh
```

The target is anything `ssh` takes, an alias from `~/.ssh/config` or `user@host`. The host needs
`go` on the `PATH` its login shell sets. The laptop needs Python 3, tmux, git, jq, rsync, Watchman and
`gtimeout`, and for `claude-band.sh` a logged-in `claude`.

## What a capture does

Each script starts a private tmux server, `tmux -L svgcap`, at 110 columns by 40 rows, and refuses to
start when that server already has a session. It never touches the default tmux server.

It copies the Go module in [demo/](demo/) to a new folder under `/tmp/wh-capture-*/`, makes it a git
repository named `demo`, and runs `wh` there. Each demo folder is new, so its first run is a first
copy on the host. `/tmp` keeps the folder's path free of a user name.

The capture writes its own hosts file with one host, `alpha`, whose ssh target is `alpha-mini`. It
asks the host for its architecture, cores and memory to fill in the rest of the line.
[ssh-alias.sh](ssh-alias.sh) is the `ssh` on the capture's `PATH`: it sends `alpha-mini` to
`WH_CAPTURE_SSH_TARGET`, so the host's real name reaches no image, no frame and no prompt that
Claude Code sends. It also drops the line some ssh configs print for each connection, which names the
host's address.

- `wh-run.sh` types into a plain `bash --noprofile --norc` shell. It runs
  `wh -- gtimeout 5m go test -v ./...`, adds a test with one `echo`, and runs the same command again.
  The capture fails unless the second run patched exactly one file. The shell prints no colors of
  its own, so one capture serves both themes, and the theme sets the default foreground and
  background.
- `claude-band.sh` starts Claude Code once per theme, with `--plugin-dir` set to this checkout,
  `--setting-sources ""`, a settings file with the theme, and `workhorse-runs@skills-dir` turned
  off so an installed copy of the mod does not draw every line twice. It accepts the trust dialog for
  the new folder and runs `! wh -- gtimeout 5m go test -bench=. ./...` in bash mode. Each frame must
  hold exactly one band line and one badge while the run goes, and neither once it ends.
  `CLAUDE_CODE_SHELL` points at [shell.sh](shell.sh), so bash mode reads no personal startup files.

Claude Code answers a bash-mode command with a model turn. The capture runs it on Haiku and takes the last
frame before the reply.

## Files

`capture.py` writes one `.ansi` file per frame and theme, and a manifest, `<image>.json`. A frame's
file holds only the rows its image shows, captured with `capture-pane -S -E`, so Claude Code's
welcome box, which names the account, never reaches a file. All 110 columns stay. The home directory
prefix becomes `~`.

`render.py` turns a manifest into an SVG without replacing or recoloring text. Each frame lasts 2.5
seconds; with reduced motion only the first one shows. The font is 13 px, cells are 7.8 px, lines are
22 px and the padding is 24 px. It changes the captured text in two ways, both to match the terminal:
a tab moves to the next tab stop, every 8 columns, and it draws the Powerline half circles at the
badge's ends (U+E0B6 and U+E0B4), which the SVG's fonts lack, as half ellipses in their cell. Terminal
hyperlinks become plain text. An SVG must stay under 80 KB.

Rebuild an SVG from the saved frames, with no host and no model call:

```bash
python3 assets/capture/render.py assets/capture/claude-band.json assets/claude-band.svg
```

The wh-run capture becomes the README's banner, [assets/banner.svg](../banner.svg): `banner.py` renders
it and draws the horse, [horse.webp](horse.webp), over its middle with a fade the color of the terminal. The horse blinks, flicks an ear, has its hair
blown about and raises an eyebrow on a 9-second loop; with reduced motion it stays still.
Rebuild it the same way:

```bash
python3 -B assets/capture/banner.py
```

## Cleanup

On exit, success or failure, a capture stops its tmux server and its Claude Code process, removes the
Watchman watch on each demo folder, and on the host removes each demo copy by its exact name,
`~/work/demo-<8 hex digits>` with its `.lock`, `.clock`, `.listing` and `.times`. After a success it
removes its `/tmp/wh-capture-*` folder; after a failure it keeps it and prints the path, with the
screen it gave up on.

Some things stay. Each `wh` run adds its lines to `~/.local/state/workhorse/runs.jsonl`, the log the
mod reads. Each `claude-band.sh` theme adds its demo folder to the trusted folders in
`~/.claude.json`, adds the typed command to `~/.claude/history.jsonl`, and leaves the session's
transcript in a folder under `~/.claude/projects/` named after the demo folder.

## Checks

```bash
set -o pipefail
xmllint --noout assets/*.svg &&
  for f in assets/capture/*.sh; do bash -n "$f"; done &&
  python3 assets/capture/check-links.py README.md assets/capture/README.md &&
  python3 assets/capture/check-privacy.py
```

[check-privacy.py](check-privacy.py) reads every file under `assets/` (or only the files you name) with
the color codes taken out. It fails on an IPv4 or IPv6 address, an ssh connection notice, a
`.local` or tailnet host name, a home path, Claude plan or account text, and an email address outside
the reserved example domains. It also fails on your user name, your home folder's name, your machine's
name, your git email, and the user and host in `WH_CAPTURE_SSH_TARGET`. Names that must not appear
even in the script go in a file outside the repository, one regular expression per line, named by
`WH_PRIVACY_PATTERNS`. It prints the file, the line and the kind of hit, never the text. Every
capture runs it on its own files before it copies them here.
