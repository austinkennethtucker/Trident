#!/usr/bin/env bash
set -euo pipefail

# Build and install Trident to a prefix directory.
#
# Usage:
#   ./linux/install.sh                       # Install to /usr/local (default, uses sudo)
#   ./linux/install.sh /usr                  # Install to /usr (uses sudo)
#   ./linux/install.sh ~/.local              # Install to home dir (no sudo needed)
#   OPTIMIZE=Debug ./linux/install.sh        # Debug build

PREFIX="${1:-/usr/local}"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Find zig binary (sudo strips PATH, so check common locations)
ZIG="${ZIG:-$(command -v zig 2>/dev/null || echo "")}"
if [ -z "$ZIG" ]; then
    for p in /usr/local/bin/zig /opt/zig/zig /opt/zig-*/zig /snap/bin/zig "$HOME/.local/bin/zig"; do
        if [ -x "$p" ]; then ZIG="$p"; break; fi
    done
fi
if [ -z "$ZIG" ]; then
    echo "Error: zig not found. Set ZIG=/path/to/zig or add zig to PATH."
    exit 1
fi

cd "$REPO_ROOT"

echo "==> Building Trident (optimize=${OPTIMIZE}, prefix=${PREFIX})"
echo "    Using zig: ${ZIG}"
"$ZIG" build \
    "-Doptimize=${OPTIMIZE}" \
    -Dcpu=baseline \
    -Dpie=true \
    --prefix "${PREFIX}"

echo "==> Installed to ${PREFIX}"
echo "    Binary:       ${PREFIX}/bin/ghostty"
echo "    Desktop file: ${PREFIX}/share/applications/"
echo "    Icons:        ${PREFIX}/share/icons/hicolor/"
echo "    Man pages:    ${PREFIX}/share/man/"
echo "    Completions:  ${PREFIX}/share/bash-completion/ ${PREFIX}/share/zsh/ ${PREFIX}/share/fish/"
