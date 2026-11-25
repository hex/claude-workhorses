#!/bin/bash
# ABOUTME: Installs the Command Line Tools straight from Apple's signed packages, for when softwareupdate wedges.
# ABOUTME: Takes the product softwareupdate last tried from /var/log/install.log; needs SUDO_ASKPASS, as setup.sh has.
set -euo pipefail

# softwareupdate logs the swcdn URL of every package of the product it starts downloading.
executables_url=$(grep -ohE 'https://swcdn\.apple\.com/content/downloads/[^" ]+/CLTools_Executables\.pkg' /var/log/install.log | tail -1 || true)
if [ -z "$executables_url" ]; then
  echo "clt-direct: /var/log/install.log names no CLTools_Executables.pkg download; softwareupdate never started one" >&2
  exit 1
fi
base=${executables_url%/*}
product=$(sed -nE 's#^.*/([0-9]+-[0-9]+)-[A-Z]_[^/]+/[^/]+$#\1#p' <<<"$base")
if [ -z "$product" ]; then
  echo "clt-direct: no product id in $base" >&2
  exit 1
fi

# The product's distribution file lists its packages in install order.
dist=$(curl -fsS "${base/swcdn.apple.com/swdist.apple.com}/$product.English.dist")
packages=()
while IFS= read -r package; do packages+=("$package"); done < <(
  grep -oE '<pkg-ref id="[^"]+"[^>]*>[^<]+\.pkg</pkg-ref>' <<<"$dist" | sed -E 's#^.*>([^<]+)</pkg-ref>$#\1#'
)
if [ "${#packages[@]}" -eq 0 ]; then
  echo "clt-direct: the distribution file of product $product lists no packages" >&2
  exit 1
fi
echo "clt-direct: product $product, ${#packages[@]} packages: ${packages[*]}" >&2

# Download and check every package before installing any, so a bad download installs nothing.
download=$(mktemp -d /tmp/clt-direct.XXXXXX)
trap 'rm -rf "$download"' EXIT
for package in "${packages[@]}"; do
  curl -fsSL -o "$download/$package" "$base/$package"
  signature=$(pkgutil --check-signature "$download/$package")
  if ! grep -q 'Status: signed Apple Software' <<<"$signature" || ! grep -q 'Apple Root CA' <<<"$signature"; then
    echo "clt-direct: $package from $base is not signed by Apple:" >&2
    echo "$signature" >&2
    exit 1
  fi
done
for package in "${packages[@]}"; do
  sudo -A installer -pkg "$download/$package" -target /
done
