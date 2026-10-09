#!/usr/bin/env bash
# Install the frozen backend binary as a user systemd service so it runs
# automatically at login (and the app finds it already up).
# Usage: tools/install_backend_service.sh [--bin path/to/localsearch-backend]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$BIN" ]]; then
  for c in "$ROOT/dist/linux/bin/localsearch-backend" ./localsearch-backend; do
    [[ -x "$c" ]] && BIN="$c" && break
  done
fi
[[ -n "$BIN" && -x "$BIN" ]] || {
  echo "no backend binary found; build it first (see README packaging)" >&2
  exit 1
}

mkdir -p ~/.local/bin ~/.config/systemd/user
install -m755 "$BIN" ~/.local/bin/localsearch-backend
cp "$ROOT/packaging/localsearch-backend.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now localsearch-backend.service
loginctl enable-linger "$USER" 2>/dev/null || true
echo "service running: $(systemctl --user is-active localsearch-backend.service)"
