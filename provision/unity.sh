#!/bin/bash
# ABOUTME: Installs Unity Hub, the unity CLI and the pinned Unity editor with Android, iOS and WebGL on a workhorse.
# ABOUTME: Run as the workhorse user after setup.sh; safe to re-run. Licensing is not handled here.
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/local/bin:$PATH"
editor_version=6000.3.28f1
editor_changeset=8f082d2fe476

if ! [ -d "/Applications/Unity Hub.app" ]; then
  hub_dir=$(mktemp -d /tmp/hub.XXXX)
  curl -fsSL -o "$hub_dir/hub.dmg" https://public-cdn.cloud.unity3d.com/hub/prod/UnityHubSetup-x64.dmg
  hub_mount=$(hdiutil attach -nobrowse -readonly "$hub_dir/hub.dmg" | awk -F'\t' '/Apple_HFS|Apple_APFS/{print $NF}' | tail -1)
  codesign --verify --deep --strict "$hub_mount/Unity Hub.app"
  hub_signature=$(codesign -dv "$hub_mount/Unity Hub.app" 2>&1)
  grep -q '^TeamIdentifier=9QW8UQUTAA$' <<<"$hub_signature"
  ditto "$hub_mount/Unity Hub.app" "/Applications/Unity Hub.app"
  hdiutil detach -quiet "$hub_mount"
  rm -rf "$hub_dir"
fi

# SHELL=/bin/sh stops the installer from appending to ~/.zshenv, which sync.sh owns.
if ! [ -x "$HOME/.unity/bin/unity" ]; then
  curl -fsSL https://unity.com/install.sh | SHELL=/bin/sh bash
fi
# The env file is not written for set -u.
set +u; . "$HOME/.unity/env"; set -u

if ! [ -d "/Applications/Unity/Hub/Editor/$editor_version" ]; then
  unity --non-interactive install "$editor_version" -c "$editor_changeset" -a x86_64 -m android ios webgl --cm --accept-eula --set-default
fi

echo "--- unity result"
unity --version
# A half-finished install leaves the editor folder behind, so check the modules too.
installed=$(unity --non-interactive editors -i 2>&1)
for module in Android iOS Web; do
  grep -qi "$module" <<<"$installed" || { echo "unity: $editor_version has no $module module" >&2; exit 1; }
done
"/Applications/Unity/Hub/Editor/$editor_version/Unity.app/Contents/MacOS/Unity" -version
