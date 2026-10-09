#!/usr/bin/env bash
# Dev loop: backend in background + Flutter app in foreground.
# Usage: tools/run_dev.sh [linux|macos|windows|chrome]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${1:-linux}"
VENV="$ROOT/backend/.venv"

[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q torch torchvision \
  --index-url https://download.pytorch.org/whl/cpu
"$VENV/bin/pip" install -q sentence-transformers fastapi "uvicorn[standard]" \
  pydantic numpy pillow pypdf httpx imageio-ffmpeg pytest

(cd "$ROOT/backend" && "$VENV/bin/python" -m app.main &>/tmp/localsearch-backend.log &)
echo "backend log: /tmp/localsearch-backend.log"
trap 'kill %1 2>/dev/null' EXIT

(cd "$ROOT/app" && flutter run -d "$DEVICE")
