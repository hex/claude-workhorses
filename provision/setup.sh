#!/bin/bash
# ABOUTME: Privileged setup that turns a Mac mini into an unattended agent workhorse.
# ABOUTME: Run as the workhorse user with SUDO_ASKPASS=~/.local/bin/askpass-env, SUDO_PW and WORKHORSE_PROFILE set; safe to re-run.
set -euo pipefail

# dedicated: the Mac is the workhorse's alone. shared: its owner uses it too, so the workhorse user
# leaves the owner's login, remote access and network security as they are, and never needs a screen.
profile=${WORKHORSE_PROFILE:?sync.sh sets the profile: dedicated or shared}
case "$profile" in
  dedicated | shared) ;;
  *) echo "unknown WORKHORSE_PROFILE \"$profile\"; known: dedicated, shared" >&2; exit 1 ;;
esac

sudo -A -v

# Agents run unattended: never idle-sleep, come back after a power cut.
sudo -A pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1

# Agents churn many files (clones, node_modules); Spotlight indexing them only burns CPU.
sudo -A mdutil -a -i off

if ! xcode-select -p >/dev/null 2>&1; then
  # This marker makes softwareupdate list the Command Line Tools package.
  marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$marker"
  label=$(softwareupdate -l 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools for Xcode-.*\)$/\1/p' | sort -V | tail -1)
  if [ -z "$label" ]; then
    rm -f "$marker"
    echo "softwareupdate lists no Command Line Tools package" >&2
    exit 1
  fi
  # softwareupdate can wedge on this install for good, even across reboots. If it fails or runs past
  # 30 minutes, install Apple's packages directly.
  sudo -A softwareupdate -i "$label" --verbose &
  update_pid=$!
  for _ in $(seq 360); do
    kill -0 "$update_pid" 2>/dev/null || break
    sleep 5
  done
  if kill -0 "$update_pid" 2>/dev/null; then
    echo "softwareupdate is still installing '$label' after 30 minutes; installing the packages directly" >&2
    kill "$update_pid"
    wait "$update_pid" || true
    "$(dirname "$0")/clt-direct.sh"
  elif ! wait "$update_pid"; then
    echo "softwareupdate failed to install '$label'; installing the packages directly" >&2
    "$(dirname "$0")/clt-direct.sh"
  fi
  rm -f "$marker"
  xcode-select -p >/dev/null || { echo "the Command Line Tools are still missing after the install" >&2; exit 1; }
fi

# Homebrew refuses Intel Macs and, on a shared Mac, belongs to the owner's account, so packages come
# from MacPorts, whose installer is built for each macOS release.
case "$(sw_vers -productVersion | cut -d. -f1)" in
  15) macports_pkg=MacPorts-2.12.7-15-Sequoia.pkg ;;
  27) macports_pkg=MacPorts-2.12.7-27-GoldenGate.pkg ;;
  *) echo "no MacPorts installer chosen for macOS $(sw_vers -productVersion)" >&2; exit 1 ;;
esac
if ! [ -x /opt/local/bin/port ]; then
  curl -fsSL -o "/tmp/$macports_pkg" "https://github.com/macports/macports-base/releases/download/v2.12.7/$macports_pkg"
  macports_signature=$(pkgutil --check-signature "/tmp/$macports_pkg")
  grep -q 'Developer ID Installer: Joshua Root (QTA3A3B7F3)' <<<"$macports_signature"
  sudo -A installer -pkg "/tmp/$macports_pkg" -target /
  rm -f "/tmp/$macports_pkg"
fi
# Ports build with the Command Line Tools. A shared Mac's owner may keep an Xcode.app older than the
# macOS release, and MacPorts refuses to build with it; ignoring Xcode keeps every workhorse alike.
macports_conf=/opt/local/etc/macports/macports.conf
for setting in "developer_dir /Library/Developer/CommandLineTools" "xcodeversion none" "xcodebuildcmd none"; do
  grep -qx "$setting" "$macports_conf" || echo "$setting" | sudo -A tee -a "$macports_conf" >/dev/null
done
sudo -A /opt/local/bin/port -N selfupdate
# Upgrade what is already installed too, so hosts synced on different days still match.
if [ -n "$(/opt/local/bin/port -q outdated)" ]; then sudo -A /opt/local/bin/port -N upgrade outdated; fi
sudo -A /opt/local/bin/port -N install tmux gh nodejs24 npm11 jq

# Agent CLIs live in ~/.local so they update without sudo; ~/.zshenv puts it on PATH.
export PATH="$HOME/.local/bin:/opt/local/bin:$PATH"
# Every sync moves the agent CLIs to their latest release, so hosts synced together match.
if [ -x "$HOME/.local/bin/claude" ]; then claude update; else curl -fsSL https://claude.ai/install.sh | bash; fi
npm config set prefix "$HOME/.local"
npm install -g @openai/codex@latest
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
uv tool install --upgrade --python 3.12 macos-harness

# Key-only SSH. sshd keeps the first value it reads, so 050 must sort before 100-macos.conf.
if [ "$profile" = dedicated ]; then
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo -A tee /etc/ssh/sshd_config.d/050-key-only.conf >/dev/null
  sudo -A /usr/sbin/sshd -t
fi

# Agent builds open many files; raise the limit now and at every boot.
sudo -A tee /Library/LaunchDaemons/limit.maxfiles.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>limit.maxfiles</string>
  <key>ProgramArguments</key>
  <array><string>launchctl</string><string>limit</string><string>maxfiles</string><string>65536</string><string>200000</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
sudo -A chown root:wheel /Library/LaunchDaemons/limit.maxfiles.plist
sudo -A chmod 644 /Library/LaunchDaemons/limit.maxfiles.plist
sudo -A launchctl bootstrap system /Library/LaunchDaemons/limit.maxfiles.plist 2>/dev/null || sudo -A launchctl kickstart -k system/limit.maxfiles

# A neutral git identity for test suites that commit.
git config --global user.name "$(id -un) workhorse"
git config --global user.email "$(id -un)@localhost"
git config --global init.defaultBranch main

# A shared Mac is its owner's: the workhorse user never logs in on its screen, and the owner keeps
# their own remote access and Tailscale.
if [ "$profile" = dedicated ]; then
  # No screensaver or Siri on a headless box; a Dock with only the tools used over Screen Sharing.
  defaults -currentHost write com.apple.screensaver idleTime -int 0
  defaults write com.apple.assistant.support "Assistant Enabled" -bool false
  dock_apps=(/System/Applications/Utilities/Terminal.app/ /System/Applications/Utilities/Activity%20Monitor.app/ /System/Applications/System%20Settings.app/)
  current_dock=$(defaults read com.apple.dock persistent-apps 2>/dev/null | sed -n 's/.*"_CFURLString" = "file:\/\/\(.*\)";/\1/p')
  if [ "$current_dock" != "$(printf '%s\n' "${dock_apps[@]}")" ]; then
    dock_backup="$HOME/dock-backup.plist"
    [ -f "$dock_backup" ] || defaults export com.apple.dock "$dock_backup"
    dock_tile() { echo "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$1</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>"; }
    dock_tiles=()
    for app in "${dock_apps[@]}"; do dock_tiles+=("$(dock_tile "$app")"); done
    defaults write com.apple.dock persistent-apps -array "${dock_tiles[@]}"
    defaults write com.apple.dock show-recents -bool false
    killall Dock || true
  fi

  # Each workhorse gets its own solid wallpaper (chosen in sync.sh) so Screen Sharing windows are easy to tell apart.
  wallpaper="/System/Library/Desktop Pictures/Solid Colors/${WORKHORSE_WALLPAPER:?sync.sh sets the wallpaper colour}.png"
  [ -f "$wallpaper" ] || { echo "no wallpaper at $wallpaper" >&2; exit 1; }
  osascript -e "tell application \"System Events\" to set picture of every desktop to \"$wallpaper\""

  # Under Remote Management, Screen Sharing ignores admin rights and rejects any user without ARD privileges.
  # Restarting the agent drops a live Screen Sharing session, so only grant when the privileges are missing.
  if ! dscl . -read "/Users/$(id -un)" naprivs >/dev/null 2>&1; then
    sudo -A /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
      -configure -access -on -users "$(id -un)" -privs -all -restart -agent
  fi

  # Agents on the box drive app UIs through macos-harness; give Claude its skill.
  mkdir -p "$HOME/.claude/skills/macos-harness"
  macos-harness skill > "$HOME/.claude/skills/macos-harness/SKILL.md"

  # Official Tailscale (signed by Tailscale Inc.); login and extension approval happen on screen.
  tailscale_pkg=Tailscale-1.104.7-macos.pkg
  if ! [ -d /Applications/Tailscale.app ]; then
    curl -fsSL -o "/tmp/$tailscale_pkg" "https://pkgs.tailscale.com/stable/$tailscale_pkg"
    tailscale_signature=$(pkgutil --check-signature "/tmp/$tailscale_pkg")
    grep -q 'Developer ID Installer: Tailscale Inc. (W5364U7YZB)' <<<"$tailscale_signature"
    sudo -A installer -pkg "/tmp/$tailscale_pkg" -target /
    rm -f "/tmp/$tailscale_pkg"
  fi
fi

# Log the workhorse user in at boot, so Tailscale and other login items come back after a reboot.
# /etc/kcpassword is loginwindow's format: the password plus a NUL, padded with NULs to a multiple
# of 12 bytes, XORed with Apple's fixed 11-byte key. Python reads SUDO_PW from its env, never argv.
# A shared Mac logs its owner in instead.
if [ "$profile" = dedicated ] && { [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" != "$(id -un)" ] ||
  ! sudo -A test -s /etc/kcpassword; }; then
  /usr/bin/python3 -I -c '
import os, sys
key = bytes([0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F])
data = os.environ["SUDO_PW"].encode() + b"\0"
data += b"\0" * (-len(data) % 12)
sys.stdout.buffer.write(bytes(b ^ key[i % len(key)] for i, b in enumerate(data)))
' | sudo -A tee /etc/kcpassword >/dev/null
  sudo -A chown root:wheel /etc/kcpassword
  sudo -A chmod 600 /etc/kcpassword
  sudo -A defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$(id -un)"
fi

# The macOS firewall blocks inbound connections to anything unsigned and answers no probes (stealth).
# Apple-signed services (Remote Login, Screen Sharing) and signed apps (Tailscale) keep working;
# wh copies repositories over SSH and opens no port.
# A shared Mac's owner may serve unsigned apps (a dev server) to other machines, so it keeps their setting.
if [ "$profile" = dedicated ]; then
  firewall=/usr/libexec/ApplicationFirewall/socketfilterfw
  sudo -A "$firewall" --setglobalstate on
  sudo -A "$firewall" --setallowsigned on
  sudo -A "$firewall" --setallowsignedapp on
  sudo -A "$firewall" --setstealthmode on
fi

# With Wi-Fi up, the Bonjour name also resolves to the Wi-Fi address and laptop traffic can take the
# slower link. Turn Wi-Fi off, but only while Ethernet is active, so a mini without a cable stays reachable.
wifi_device=$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi$/{getline; print $2}')
ethernet_device=$(networksetup -listallhardwareports | awk '/^Hardware Port: Ethernet$/{getline; print $2}')
if [ "$(ifconfig "$ethernet_device" | awk '/status:/{print $2}')" = active ]; then
  sudo -A networksetup -setairportpower "$wifi_device" off
else
  echo "Ethernet ($ethernet_device) is not active; leaving Wi-Fi on" >&2
fi

echo "--- result"
pmset -g | grep -E ' sleep|displaysleep|disksleep|autorestart|powernap'
mdutil -s /
xcode-select -p
/opt/local/bin/port version
tmux -V; gh --version | head -1; node --version
claude --version; codex --version
# OpenSSH 10 prints these keys capitalised, 9 in lower case.
sudo -A /usr/sbin/sshd -T 2>/dev/null | grep -iE "^(passwordauthentication|kbdinteractiveauthentication) " | tr '[:upper:]' '[:lower:]'
launchctl limit maxfiles
jq --version; git config --global user.email
# The rest reports on steps a shared Mac leaves out.
[ "$profile" = dedicated ] || exit 0
defaults read /Applications/Tailscale.app/Contents/Info CFBundleShortVersionString

# Over SSH, macOS charges macos-harness's permissions to sshd-keygen-wrapper, not to the python that
# `macos-harness doctor` names. Granting them takes a click on the Mac's screen, so only report.
tcc_grants=$(sudo -A sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service from access where client = '/usr/libexec/sshd-keygen-wrapper' and auth_value = 2")
for grant in "Accessibility:Accessibility" "ScreenCapture:Screen & System Audio Recording"; do
  if grep -qx "kTCCService${grant%%:*}" <<<"$tcc_grants"; then
    echo "sshd-keygen-wrapper has ${grant#*:}"
  else
    echo "macos-harness over SSH needs ${grant#*:}: in Privacy & Security on this Mac's screen, grant it to /usr/libexec/sshd-keygen-wrapper" >&2
  fi
done
