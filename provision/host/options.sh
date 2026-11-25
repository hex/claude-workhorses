#!/bin/bash
# ABOUTME: Applies or reports one host option on this workhorse: options.sh apply|probe <option>.
# ABOUTME: The options come from the hosts file; sync.sh checks them and hands sudo only to the ones that need it.
set -euo pipefail

# Runs a command through sudo with the askpass helper; only options sync.sh marks as needing sudo call it.
as_root() { sudo -A "$@"; }

apply() {
  case "$1" in
    no-sleep)
      # Agents run unattended: never idle-sleep, come back after a power cut, wake on LAN.
      as_root pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1 ;;
    no-spotlight)
      # Agents churn many files (clones, node_modules); Spotlight indexing them only burns CPU.
      as_root mdutil -a -i off ;;
    maxfiles)
      # Agent builds open many files; raise the limit now and at every boot.
      as_root tee /Library/LaunchDaemons/limit.maxfiles.plist >/dev/null <<'PLIST'
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
      as_root chown root:wheel /Library/LaunchDaemons/limit.maxfiles.plist
      as_root chmod 644 /Library/LaunchDaemons/limit.maxfiles.plist
      as_root launchctl bootstrap system /Library/LaunchDaemons/limit.maxfiles.plist 2>/dev/null || as_root launchctl kickstart -k system/limit.maxfiles ;;
    key-only-ssh)
      # sshd keeps the first value it reads, so 050 must sort before 100-macos.conf.
      printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | as_root tee /etc/ssh/sshd_config.d/050-key-only.conf >/dev/null
      as_root /usr/sbin/sshd -t ;;
    git-identity)
      # A neutral git identity for test suites that commit.
      git config --global user.name "$(id -un) workhorse"
      git config --global user.email "$(id -un)@localhost"
      git config --global init.defaultBranch main ;;
    headless)
      # No screensaver or Siri on a Mac nobody sits at.
      defaults -currentHost write com.apple.screensaver idleTime -int 0
      defaults write com.apple.assistant.support "Assistant Enabled" -bool false ;;
    dock)
      # A Dock with only the tools used over Screen Sharing; the first change keeps a backup.
      local dock_apps current_dock dock_backup app dock_tiles=()
      dock_apps=(/System/Applications/Utilities/Terminal.app/ /System/Applications/Utilities/Activity%20Monitor.app/ /System/Applications/System%20Settings.app/)
      current_dock=$(defaults read com.apple.dock persistent-apps 2>/dev/null | sed -n 's/.*"_CFURLString" = "file:\/\/\(.*\)";/\1/p')
      if [ "$current_dock" != "$(printf '%s\n' "${dock_apps[@]}")" ]; then
        dock_backup="$HOME/dock-backup.plist"
        [ -f "$dock_backup" ] || defaults export com.apple.dock "$dock_backup"
        for app in "${dock_apps[@]}"; do
          dock_tiles+=("<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$app</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>")
        done
        defaults write com.apple.dock persistent-apps -array "${dock_tiles[@]}"
        defaults write com.apple.dock show-recents -bool false
        killall Dock || true
      fi ;;
    wallpaper=*)
      # A solid wallpaper per host, so Screen Sharing windows are easy to tell apart. sync.sh allows
      # only letters, digits and _ in the name, which stands for a space.
      local name=${1#wallpaper=} wallpaper
      wallpaper="/System/Library/Desktop Pictures/Solid Colors/${name//_/ }.png"
      [ -f "$wallpaper" ] || { echo "no wallpaper at $wallpaper" >&2; exit 1; }
      osascript -e "tell application \"System Events\" to set picture of every desktop to \"$wallpaper\"" ;;
    screensharing)
      # Under Remote Management, Screen Sharing ignores admin rights and rejects any user without ARD privileges.
      # Restarting the agent drops a live Screen Sharing session, so only grant when the privileges are missing.
      if ! dscl . -read "/Users/$(id -un)" naprivs >/dev/null 2>&1; then
        as_root /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
          -configure -access -on -users "$(id -un)" -privs -all -restart -agent
      fi ;;
    tailscale)
      # Official Tailscale (signed by Tailscale Inc.); login and extension approval happen on screen.
      local tailscale_pkg=Tailscale-1.104.7-macos.pkg tailscale_signature
      if ! [ -d /Applications/Tailscale.app ]; then
        curl -fsSL -o "/tmp/$tailscale_pkg" "https://pkgs.tailscale.com/stable/$tailscale_pkg"
        tailscale_signature=$(pkgutil --check-signature "/tmp/$tailscale_pkg")
        grep -q 'Developer ID Installer: Tailscale Inc. (W5364U7YZB)' <<<"$tailscale_signature"
        as_root installer -pkg "/tmp/$tailscale_pkg" -target /
        rm -f "/tmp/$tailscale_pkg"
      fi ;;
    autologin)
      # Log the workhorse user in at boot, so login items come back after a reboot. This stores the
      # user's password in /etc/kcpassword, root-only, in loginwindow's format: the password plus a
      # NUL, padded with NULs to a multiple of 12 bytes, XORed with Apple's fixed 11-byte key. That is
      # obfuscation, not encryption. Python reads SUDO_PW from its env, never argv.
      if [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" != "$(id -un)" ] ||
        ! as_root test -s /etc/kcpassword; then
        /usr/bin/python3 -I -c '
import os, sys
key = bytes([0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F])
data = os.environ["SUDO_PW"].encode() + b"\0"
data += b"\0" * (-len(data) % 12)
sys.stdout.buffer.write(bytes(b ^ key[i % len(key)] for i, b in enumerate(data)))
' | as_root tee /etc/kcpassword >/dev/null
        as_root chown root:wheel /etc/kcpassword
        as_root chmod 600 /etc/kcpassword
        as_root defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$(id -un)"
      fi ;;
    firewall)
      # The macOS firewall blocks inbound connections to anything unsigned and answers no probes (stealth).
      # Apple-signed services (Remote Login, Screen Sharing) and signed apps (Tailscale) keep working;
      # wh copies repositories over SSH and opens no port.
      local firewall=/usr/libexec/ApplicationFirewall/socketfilterfw
      as_root "$firewall" --setglobalstate on
      as_root "$firewall" --setallowsigned on
      as_root "$firewall" --setallowsignedapp on
      as_root "$firewall" --setstealthmode on ;;
    wifi-off)
      # With Wi-Fi up, the Bonjour name also resolves to the Wi-Fi address and traffic can take the
      # slower link. Turn Wi-Fi off, but only while Ethernet is active, so a Mac without a cable stays reachable.
      local wifi_device ethernet_device
      wifi_device=$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi$/{getline; print $2}')
      ethernet_device=$(networksetup -listallhardwareports | awk '/^Hardware Port: Ethernet$/{getline; print $2}')
      if [ -n "$ethernet_device" ] && [ "$(ifconfig "$ethernet_device" | awk '/status:/{print $2}')" = active ]; then
        as_root networksetup -setairportpower "$wifi_device" off
      else
        echo "Ethernet ($ethernet_device) is not active; leaving Wi-Fi on" >&2
      fi ;;
    *) echo "options.sh: unknown host option \"$1\"" >&2; exit 1 ;;
  esac
}

# Prints one line, "<name> <state>", for what option $1 changed; reading it needs no sudo.
probe() {
  case "$1" in
    no-sleep) echo "pmset $(pmset -g custom | grep -E ' (sleep|displaysleep|disksleep|autorestart|powernap) ' | tr -s ' ' | sort -u | tr '\n' ' ')" ;;
    no-spotlight) echo "spotlight $(mdutil -s / 2>&1 | tail -1 | tr -s '\t ' ' ')" ;;
    maxfiles) echo "maxfiles $(launchctl limit maxfiles | tr -s ' ')" ;;
    key-only-ssh) echo "sshd $(/usr/sbin/sshd -G 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication) ' | tr '[:upper:]\n' '[:lower:] ')" ;;
    git-identity) echo "git-identity $(git config --global user.email 2>/dev/null || echo none)" ;;
    headless) echo "headless screensaver-idle $(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo unset) siri $(defaults read com.apple.assistant.support "Assistant Enabled" 2>/dev/null || echo unset)" ;;
    dock) echo "dock $(defaults read com.apple.dock persistent-apps 2>/dev/null | grep -c '"_CFURLString" =') apps" ;;
    wallpaper=*) echo "wallpaper ${1#wallpaper=}" ;;
    screensharing) echo "screensharing $(dscl . -read "/Users/$(id -un)" naprivs >/dev/null 2>&1 && echo granted || echo not-granted)" ;;
    tailscale) echo "tailscale $(defaults read /Applications/Tailscale.app/Contents/Info CFBundleShortVersionString 2>&1)" ;;
    autologin) echo "autologin $([ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$(id -un)" ] && echo own-user || echo off)" ;;
    firewall) echo "firewall $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep -o 'State = [0-9]') $(/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode | grep -o 'is [a-z]*$')" ;;
    wifi-off) echo "wifi $(networksetup -getairportpower "$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi$/{getline; print $2}')" | awk '{print $NF}')" ;;
    *) echo "options.sh: unknown host option \"$1\"" >&2; exit 1 ;;
  esac
}

case "${1:-}" in
  apply | probe) "$1" "${2:?options.sh $1 takes one option}" ;;
  *) echo "usage: options.sh apply|probe <option>" >&2; exit 2 ;;
esac
