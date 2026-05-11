#!/usr/bin/env bash
# install-remote.sh — bootstrap installer fetched via curl.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mynenikoteshwarrao/claude-context-manager/main/install-remote.sh | bash

set -euo pipefail

REPO="${CCM_RELEASE_REPO:-mynenikoteshwarrao/claude-context-manager}"
INSTALL_DIR="${CCM_INSTALL_DIR:-$HOME/.local/share/ccm}"

echo "ccm bootstrap installer"
echo "  repo:   $REPO"
echo "  target: $INSTALL_DIR"

for tool in curl jq tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool"; exit 1; }
done

# Resolve latest release tag.
tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | jq -r '.tag_name')"
if [ -z "$tag" ] || [ "$tag" = "null" ]; then
  echo "Could not resolve latest tag." >&2
  exit 1
fi
echo "  tag:    $tag"

# Download tarball.
tmp="$(mktemp -d -t ccm-bootstrap-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
tarball="$tmp/ccm.tar.gz"
url="https://github.com/$REPO/releases/download/$tag/claude-context-manager-${tag#v}.tar.gz"
echo "Downloading $url"
curl -fsSL "$url" -o "$tarball"

# Verify SHA256 if available.
if curl -fsSL "https://github.com/$REPO/releases/download/$tag/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
  ( cd "$tmp" && shasum -a 256 -c SHA256SUMS 2>/dev/null \
                 || sha256sum -c SHA256SUMS ) || { echo "Checksum failed."; exit 1; }
fi

# Extract.
mkdir -p "$INSTALL_DIR"
tar -xzf "$tarball" -C "$INSTALL_DIR" --strip-components=1

# Run the bundled install.
bash "$INSTALL_DIR/install.sh"
