#!/usr/bin/env bash
set -euo pipefail

# Download and install the latest Trident .deb from CI artifacts.
#
# Usage:
#   sudo ./linux/install-deb.sh
#
# Requires: gh (GitHub CLI), authenticated

REPO="austinkennethtucker/ghostty"
WORKFLOW="Release Linux Packages"
ARTIFACT="trident-deb"
TMPDIR="$(mktemp -d)"

trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Finding latest successful build..."
RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --status success --limit 1 --json databaseId --jq '.[0].databaseId')"

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
    echo "Error: No successful builds found for '$WORKFLOW'."
    echo "Trigger one with: gh workflow run '$WORKFLOW' --repo $REPO"
    exit 1
fi

echo "==> Downloading .deb from run #${RUN_ID}..."
gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT" --dir "$TMPDIR"

DEB="$(ls "$TMPDIR"/*.deb 2>/dev/null | head -1)"
if [ -z "$DEB" ]; then
    echo "Error: No .deb found in artifact."
    exit 1
fi

# Check for conflicting snap Ghostty installation
if command -v snap >/dev/null 2>&1 && snap list ghostty >/dev/null 2>&1; then
    echo "WARNING: Snap package 'ghostty' is installed (upstream Ghostty)."
    echo "  The snap binary at /snap/bin/ghostty may shadow Trident and lacks"
    echo "  Trident-specific features (pane tabs, popups, vi mode, etc.)."
    echo "  Remove it with: sudo snap remove ghostty"
    echo ""
fi

echo "==> Installing $(basename "$DEB")..."
dpkg -i "$DEB" || apt-get install -f -y

echo "==> Done! Run 'trident' (or 'ghostty') to launch."
