#!/usr/bin/env bash
set -euo pipefail

# Build Trident and package into .deb, .rpm, and tarball.
#
# Usage:
#   ./linux/package.sh              # Build + package all formats
#   ./linux/package.sh --skip-build # Package existing staging dir
#
# Output: dist/trident_<version>_<arch>.{deb,rpm,tar.gz}

SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
STAGING="$REPO_ROOT/staging"
DIST="$REPO_ROOT/dist"

cd "$REPO_ROOT"

# --- Determine version and architecture ---
if [ -f VERSION ]; then
    VERSION="$(cat VERSION)"
else
    VERSION="$(git describe --tags --always 2>/dev/null || echo "0.0.0-dev")"
fi
# Strip leading 'v' if present
VERSION="${VERSION#v}"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  NFPM_ARCH="amd64" ;;
    aarch64) NFPM_ARCH="arm64" ;;
    *)       NFPM_ARCH="$ARCH" ;;
esac

echo "==> Version: ${VERSION}, Arch: ${ARCH} (nfpm: ${NFPM_ARCH})"

# --- Build into staging prefix ---
if [ "$SKIP_BUILD" = false ]; then
    echo "==> Cleaning build cache..."
    rm -rf "$REPO_ROOT/.zig-cache"
    echo "==> Building Trident (ReleaseFast) into staging..."
    rm -rf "$STAGING"
    zig build \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dpie=true \
        -Dstrip=true \
        --prefix "$STAGING/usr"
    echo "==> Build complete."
fi

if [ ! -d "$STAGING/usr/bin" ]; then
    echo "Error: staging/usr/bin not found. Run without --skip-build first."
    exit 1
fi

# --- Package ---
mkdir -p "$DIST"

# Generate nfpm config from template
export VERSION ARCH="$NFPM_ARCH"
envsubst < "$SCRIPT_DIR/nfpm.yaml" > "$REPO_ROOT/nfpm-generated.yaml"

echo "==> Building .deb package..."
nfpm pkg \
    --config "$REPO_ROOT/nfpm-generated.yaml" \
    --packager deb \
    --target "$DIST/"

echo "==> Building .rpm package..."
nfpm pkg \
    --config "$REPO_ROOT/nfpm-generated.yaml" \
    --packager rpm \
    --target "$DIST/"

echo "==> Creating tarball..."
tar czf "$DIST/trident-${VERSION}-linux-${ARCH}.tar.gz" -C "$STAGING" .

rm -f "$REPO_ROOT/nfpm-generated.yaml"

echo "==> Packages:"
ls -lh "$DIST"/trident*
