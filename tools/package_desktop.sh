#!/usr/bin/env bash
# Build a desktop bundle: backend binary + Flutter release app.
# Usage: tools/package_desktop.sh [--os linux|macos|windows] [--skip-backend]
# Model weights are NOT bundled; they download on first run (~1.5GB).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="linux"
BACKEND=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS="$2"; shift 2 ;;
    --skip-backend) BACKEND=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$OS" in
  linux|macos|windows) ;;
  *) echo "--os must be linux, macos or windows" >&2; exit 1 ;;
esac

DIST="$ROOT/dist/$OS"
mkdir -p "$DIST"

if [[ "$BACKEND" == 1 ]]; then
  VENV="$ROOT/backend/.venv-pkg"
  [[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q torch torchvision \
    --index-url https://download.pytorch.org/whl/cpu
  "$VENV/bin/pip" install -q sentence-transformers fastapi "uvicorn[standard]" \
    pydantic numpy pillow pypdf httpx imageio-ffmpeg pyinstaller
  (cd "$ROOT" && "$VENV/bin/pyinstaller" --clean --noconfirm \
    --distpath "$DIST/bin" backend/localsearch-backend.spec)
fi

(cd "$ROOT/app" && flutter build "$OS" --release)

case "$OS" in
  linux) cp -r "$ROOT/app/build/linux/x64/release/bundle" "$DIST/app" ;;
  macos) cp -r "$ROOT/app/build/macos/Build/Products/Release/"*.app "$DIST/" ;;
  windows) cp -r "$ROOT/app/build/windows/x64/runner/Release" "$DIST/app" ;;
esac

cat > "$DIST/RUN.txt" <<'EOF'
1. Start the backend:  ./bin/localsearch-backend   (listens on 127.0.0.1:39281)
2. Start the app from ./app
First run downloads the embedding model (~1.5GB) into the HF cache.
EOF
echo "bundle ready: $DIST"
