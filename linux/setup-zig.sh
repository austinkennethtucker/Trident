#!/usr/bin/env bash
set -euo pipefail

# Install Zig 0.15.2 on Linux (x86_64 or aarch64).
#
# Usage:
#   sudo ./linux/setup-zig.sh

ZIG_VERSION="0.15.2"
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)  ZIG_ARCH="x86_64" ;;
    aarch64) ZIG_ARCH="aarch64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

TARBALL="zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
INSTALL_DIR="/opt/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}"

if [ -x "$INSTALL_DIR/zig" ]; then
    echo "Zig ${ZIG_VERSION} already installed at ${INSTALL_DIR}"
    zig version
    exit 0
fi

echo "==> Downloading Zig ${ZIG_VERSION} for ${ZIG_ARCH}..."
cd /tmp
wget -q --show-progress "$URL"

echo "==> Installing to ${INSTALL_DIR}..."
sudo tar xf "$TARBALL" -C /opt/
sudo ln -sf "$INSTALL_DIR/zig" /usr/local/bin/zig
rm -f "$TARBALL"

echo "==> Installed:"
zig version

# Add to PATH in shell profile if not already there
PROFILE="${HOME}/.bashrc"
[ -f "${HOME}/.zshrc" ] && PROFILE="${HOME}/.zshrc"
if ! grep -q "/usr/local/bin" "$PROFILE" 2>/dev/null; then
    echo 'export PATH="/usr/local/bin:$PATH"' >> "$PROFILE"
    echo "==> Added /usr/local/bin to PATH in ${PROFILE}"
    echo "    Run: source ${PROFILE}"
fi
