#!/usr/bin/env bash
# Build the Ubuntu .deb for the LocalSearch Flutter app (release).
# Prereqs: flutter, dpkg-deb, patchelf, strip (binutils).
# Usage: tools/build_deb.sh
# Output: dist/localsearch_<version>_amd64.deb
# Note: the Python backend is NOT bundled; run it separately (see README).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
VERSION="$(grep '^version:' "$APP/pubspec.yaml" | sed 's/version: //; s/+.*//; s/ //g')"
ARCH="amd64"
PKG="localsearch"

(cd "$APP" && flutter build linux --release)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/lib" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/scalable/apps" \
  "$STAGE/usr/share/man/man1" \
  "$STAGE/usr/share/doc/localsearch"

cp -r "$APP/build/linux/x64/release/bundle" "$STAGE/usr/lib/localsearch"
ln -s ../lib/localsearch/localsearch "$STAGE/usr/bin/localsearch"
cp "$ROOT/packaging/localsearch.desktop" "$STAGE/usr/share/applications/"
cp "$ROOT/packaging/localsearch.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/"
cp "$ROOT/packaging/copyright" "$STAGE/usr/share/doc/localsearch/"
gzip -9 -n -c "$ROOT/packaging/changelog" > "$STAGE/usr/share/doc/localsearch/changelog.gz"
gzip -9 -n -c "$ROOT/packaging/localsearch.1" > "$STAGE/usr/share/man/man1/localsearch.1.gz"

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/usr/lib/localsearch/localsearch"
strip --strip-unneeded "$STAGE/usr/lib/localsearch/localsearch" "$STAGE"/usr/lib/localsearch/lib/*.so
# Drop build-tree RUNPATHs baked into plugin .so files; the loader
# resolves the bundled libs via the executable's $ORIGIN rpath instead.
patchelf --remove-rpath "$STAGE/usr/lib/localsearch/lib/libaudioplayers_linux_plugin.so"
patchelf --remove-rpath "$STAGE/usr/lib/localsearch/lib/libdartjni.so"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: libc6, libgtk-3-0 | libgtk-3-0t64, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good
Maintainer: LocalSearch Contributors <localsearch@example.com>
Description: Natural-language search over local files
 Local-first semantic file search powered by on-device embeddings.
 Ask in plain words ("photo where I wore a blue tshirt") and get
 ranked results with relevancy scores. 100% offline.
EOF

mkdir -p "$ROOT/dist"
dpkg-deb --build --root-owner-group "$STAGE" "$ROOT/dist/${PKG}_${VERSION}_${ARCH}.deb"
echo "deb ready: $ROOT/dist/${PKG}_${VERSION}_${ARCH}.deb"
