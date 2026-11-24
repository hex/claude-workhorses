#!/bin/zsh
# ABOUTME: Prints the installed tool versions of this workhorse, one sorted line each, host-specific values removed.
# ABOUTME: sync.sh diff runs it on every host and compares the output; run it under zsh so ~/.zshenv sets PATH.
set -uo pipefail

{
  # Dependencies (dep) differ between an Intel and an Apple silicon host: some ports pull in build
  # tools only on one of them. The ports tools.sh asks for (port) must match everywhere.
  echo "arch $(uname -m)"
  /opt/local/bin/port -q installed requested and active 2>/dev/null | sed 's/^ */port /; s/ (active)$//'
  /opt/local/bin/port -q installed active and not requested 2>/dev/null | sed 's/^ */dep /; s/ (active)$//'
  npm ls -g --depth 0 2>/dev/null | sed -n 's/^[├└]── /npm /p'
  echo "claude $(claude --version 2>&1 | head -1)"
  echo "codex $(codex --version 2>&1 | head -1)"
  echo "opencode $(opencode --version 2>&1 | head -1)"
  echo "bun $(bun --version 2>&1)"
  echo "mise-node $(mise ls --installed node 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
  echo "chrome $("$HOME/.local/bin/chrome" --version 2>&1)"
  echo "rustc $(rustc --version 2>&1)"
  echo "dotnet $(dotnet --version 2>&1)"
  echo "uv $(uv --version 2>&1 | sed 's/ [a-z0-9_]*-apple-darwin//')"
  echo "macos-harness $(uv tool list 2>/dev/null | grep '^macos-harness')"
  echo "fastlane $(GEM_HOME=$HOME/.local/share/gem gem3.4 list -e fastlane 2>/dev/null | grep '^fastlane')"
  echo "bundletool $(ls $HOME/.local/share/bundletool 2>/dev/null)"
  echo "unity-cli $(unity --version 2>&1 | head -1)"
  echo "unity-editors $(unity --non-interactive --format tsv --no-header editors -i 2>&1 | cut -f1,3,7)"
  echo "unity-hub $(defaults read '/Applications/Unity Hub.app/Contents/Info' CFBundleShortVersionString 2>&1)"
  echo "tailscale $(defaults read /Applications/Tailscale.app/Contents/Info CFBundleShortVersionString 2>&1)"
  echo "command-line-tools $(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>&1 | grep ^version)"
  echo "macos $(sw_vers -productVersion)"
  echo "pmset $(pmset -g custom | grep -E ' (sleep|displaysleep|disksleep|autorestart|powernap) ' | tr -s ' ' | sort -u | tr '\n' ' ')"
  echo "sshd $(/usr/sbin/sshd -G 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication) ' | tr '[:upper:]\n' '[:lower:] ')"
  echo "maxfiles $(launchctl limit maxfiles | tr -s ' ')"
  echo "autologin $([ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$(id -un)" ] && echo own-user || echo off)"
  echo "wifi $(networksetup -getairportpower "$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi$/{getline; print $2}')" | awk '{print $NF}')"
  echo "firewall $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep -o 'State = [0-9]') $(/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode | grep -o 'is [a-z]*$')"
  echo "dock $(defaults read com.apple.dock persistent-apps 2>/dev/null | grep -c '"_CFURLString" =') apps"
} | sort
