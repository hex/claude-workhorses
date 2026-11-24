#!/bin/bash
# ABOUTME: Installs the laptop's command-line dev tools on an Intel Mac mini workhorse for agent work.
# ABOUTME: Run as the workhorse user with SUDO_ASKPASS=~/.local/bin/askpass-env and SUDO_PW set; safe to re-run.
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/local/bin:/opt/local/sbin:$PATH"

echo "=== MacPorts"
# install leaves a port that is already there at its old version, so security releases need the
# fresh ports tree and an explicit upgrade.
sudo -A port -N selfupdate
sudo -A port -N install \
  git-lfs cmake ninja ccache ripgrep fd ast-grep bat fzf yq coreutils parallel direnv btop dua-cli \
  git-filter-repo go openjdk21-temurin mise bats-core actionlint gitleaks vale apktool ffmpeg ImageMagick7 ruby34
sudo -A port -N upgrade openjdk21-temurin
git lfs install

echo "=== Rust"
if ! [ -x "$HOME/.cargo/bin/rustup" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi

echo "=== .NET 10"
if ! [ -x "$HOME/.dotnet/dotnet" ]; then
  curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir "$HOME/.dotnet"
fi

echo "=== bun"
if [ -x "$HOME/.bun/bin/bun" ]; then "$HOME/.bun/bin/bun" upgrade; else curl -fsSL https://bun.sh/install | bash; fi

echo "=== opencode"
if [ -x "$HOME/.opencode/bin/opencode" ]; then "$HOME/.opencode/bin/opencode" upgrade; else curl -fsSL https://opencode.ai/install | bash; fi

echo "=== Node 26 (mise; MacPorts' nodejs24 stays the default node, run a repo that needs 26 with: mise exec node@26 -- <command>)"
mise install node@26

echo "=== Chrome for Testing (headless browser tests; ~/.zshenv points CHROME_BIN at ~/.local/bin/chrome)"
chrome_dir="$HOME/.local/share/chrome-for-testing"
# The installer prints "chrome@<build> <path to the binary>"; the path holds spaces.
chrome_line=$(npx --yes @puppeteer/browsers@latest install chrome@stable --path "$chrome_dir" | grep '^chrome@' | tail -1)
chrome_bin=${chrome_line#* }
[ -x "$chrome_bin" ] || { echo "Chrome for Testing printed no runnable binary: \"$chrome_line\"" >&2; exit 1; }
printf '#!/bin/sh\nexec "%s" "$@"\n' "$chrome_bin" > "$HOME/.local/bin/chrome"
chmod +x "$HOME/.local/bin/chrome"

echo "=== npm globals (prefix ~/.local)"
npm install -g pnpm@latest openupm-cli@latest uloop-cli@latest @earendil-works/pi-coding-agent@latest

echo "=== fastlane (gems under ~/.local/share/gem)"
export GEM_HOME="$HOME/.local/share/gem"
gem3.4 install --no-document --bindir "$HOME/.local/bin" fastlane
gem3.4 update --no-document --bindir "$HOME/.local/bin" fastlane

echo "=== bundletool"
bundletool_version=1.18.3
bundletool_jar="$HOME/.local/share/bundletool/bundletool-all-$bundletool_version.jar"
if ! [ -f "$bundletool_jar" ]; then
  mkdir -p "$(dirname "$bundletool_jar")"
  curl -fsSL -o "$bundletool_jar" \
    "https://github.com/google/bundletool/releases/download/$bundletool_version/bundletool-all-$bundletool_version.jar"
fi
printf '#!/bin/sh\nexec java -jar "%s" "$@"\n' "$bundletool_jar" > "$HOME/.local/bin/bundletool"
chmod +x "$HOME/.local/bin/bundletool"
