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
SYSTEM_BIN="/usr/bin/ghostty"
TRIDENT_NAME="Trident"

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

rewrite_file() {
    local file="$1"
    shift

    if [ ! -f "$file" ]; then
        return 0
    fi

    local tmp mode
    tmp="$(mktemp)"
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")"
    sed "$@" "$file" > "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$file"
}

normalize_staging_assets() {
    echo "==> Normalizing staged Linux assets for Trident..."

    # Give packaged installs a `trident` command without renaming the real
    # binary, which still uses Ghostty internals and app identifiers.
    ln -sfn ghostty "$STAGING/usr/bin/trident"

    # Zig bakes the active --prefix into generated Linux desktop assets.
    # For package builds we stage into a temporary root, so rewrite those
    # references back to their final system paths.
    local file
    while IFS= read -r file; do
        rewrite_file "$file" -e "s|${STAGING}/usr|/usr|g"
    done < <(grep -RIl --fixed-strings "${STAGING}/usr" "$STAGING/usr")

    rewrite_file "$STAGING/usr/share/applications/com.mitchellh.ghostty.desktop" \
        -e "s|^Name=Ghostty$|Name=${TRIDENT_NAME}|g" \
        -e 's|^Comment=A terminal emulator$|Comment=Trident terminal emulator|g'

    rewrite_file "$STAGING/usr/share/metainfo/com.mitchellh.ghostty.metainfo.xml" \
        -e 's|<name>Ghostty</name>|<name>Trident</name>|g' \
        -e 's|<summary>Ghostty is a fast, feature-rich, and cross-platform terminal emulator</summary>|<summary>Trident is a fast, feature-rich, and cross-platform terminal emulator</summary>|g' \
        -e 's|Ghostty is a terminal emulator|Trident is a terminal emulator forked from Ghostty|g'

    rewrite_file "$STAGING/usr/share/systemd/user/app-com.mitchellh.ghostty.service" \
        -e "s|^Description=Ghostty$|Description=${TRIDENT_NAME}|g"
    rewrite_file "$STAGING/usr/lib/systemd/user/app-com.mitchellh.ghostty.service" \
        -e "s|^Description=Ghostty$|Description=${TRIDENT_NAME}|g"

    rewrite_file "$STAGING/usr/share/kio/servicemenus/com.mitchellh.ghostty.desktop" \
        -e 's|Open Ghostty Here|Open Trident Here|g'
    rewrite_file "$STAGING/usr/share/nautilus-python/extensions/ghostty.py" \
        -e "s|label=_('Open in Ghostty')|label=_('Open in Trident')|g"
}

verify_deb_package() {
    local deb="$1"
    local workdir
    workdir="$(mktemp -d)"

    (
        cd "$workdir"
        ar x "$deb"
    )

    local control desktop dbus_service systemd_service metainfo
    control="$(tar -xOzf "$workdir/control.tar.gz" ./control)"
    desktop="$(tar -xOzf "$workdir/data.tar.gz" ./usr/share/applications/com.mitchellh.ghostty.desktop)"
    dbus_service="$(tar -xOzf "$workdir/data.tar.gz" ./usr/share/dbus-1/services/com.mitchellh.ghostty.service)"
    systemd_service="$(tar -xOzf "$workdir/data.tar.gz" ./usr/share/systemd/user/app-com.mitchellh.ghostty.service)"
    metainfo="$(tar -xOzf "$workdir/data.tar.gz" ./usr/share/metainfo/com.mitchellh.ghostty.metainfo.xml)"

    if ! grep -q '^Package: trident$' <<<"$control"; then
        echo "Error: .deb control metadata does not identify the package as 'trident'."
        exit 1
    fi

    if ! grep -q '^Name=Trident$' <<<"$desktop"; then
        echo "Error: desktop entry is not branded as Trident."
        exit 1
    fi

    if ! grep -q "^TryExec=${SYSTEM_BIN}$" <<<"$desktop"; then
        echo "Error: desktop entry TryExec is not using ${SYSTEM_BIN}."
        exit 1
    fi

    if ! grep -q "^Exec=${SYSTEM_BIN} --gtk-single-instance=true$" <<<"$desktop"; then
        echo "Error: desktop entry Exec is not using ${SYSTEM_BIN}."
        exit 1
    fi

    if ! grep -q '^Description=Trident$' <<<"$systemd_service"; then
        echo "Error: systemd user service is not branded as Trident."
        exit 1
    fi

    if ! grep -q '<name>Trident</name>' <<<"$metainfo"; then
        echo "Error: AppStream metainfo is not branded as Trident."
        exit 1
    fi

    if grep -q --fixed-strings "$STAGING" <<<"$desktop$dbus_service$systemd_service"; then
        echo "Error: packaged desktop assets still reference the staging directory."
        exit 1
    fi

    if ! tar -tzf "$workdir/data.tar.gz" | grep -q '^./usr/bin/trident$'; then
        echo "Error: packaged alias /usr/bin/trident is missing."
        exit 1
    fi

    rm -rf "$workdir"
}

normalize_staging_assets

# --- Package ---
mkdir -p "$DIST"

# Generate nfpm config from template
export VERSION ARCH="$NFPM_ARCH"
envsubst < "$SCRIPT_DIR/nfpm.yaml" > "$REPO_ROOT/nfpm-generated.yaml"

DEB_PACKAGE_PATH="$DIST/trident_${VERSION}-1_${NFPM_ARCH}.deb"

echo "==> Building .deb package..."
nfpm pkg \
    --config "$REPO_ROOT/nfpm-generated.yaml" \
    --packager deb \
    --target "$DIST/"

verify_deb_package "$DEB_PACKAGE_PATH"

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
