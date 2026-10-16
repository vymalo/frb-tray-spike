#!/usr/bin/env bash
# Builds the release bundle and installs it for the current user:
#   ~/.local/share/agent_tray_demo/        the bundle
#   ~/.local/bin/agent-tray-demo           launcher on PATH
#   ~/.local/share/applications/...desktop app grid entry
#   ~/.local/share/icons/hicolor/256x256/apps/...png
# Pass --autostart to also start it at login. Run with --uninstall to remove.
set -euo pipefail

APP_ID=dev.demo.agent_tray_demo
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
PREFIX="$DATA/agent_tray_demo"
BIN="$HOME/.local/bin/agent-tray-demo"
DESKTOP="$DATA/applications/$APP_ID.desktop"
ICON="$DATA/icons/hicolor/256x256/apps/$APP_ID.png"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$APP_ID.desktop"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$PREFIX" "$BIN" "$DESKTOP" "$ICON" "$AUTOSTART"
  update-desktop-database "$DATA/applications" 2>/dev/null || true
  echo "Uninstalled."
  exit 0
fi

cd "$ROOT"
flutter build linux --release

rm -rf "$PREFIX"
mkdir -p "$PREFIX" "$(dirname "$BIN")" "$(dirname "$DESKTOP")" "$(dirname "$ICON")"
cp -r build/linux/x64/release/bundle/. "$PREFIX/"
ln -sf "$PREFIX/agent_tray_demo" "$BIN"
cp linux/packaging/$APP_ID.png "$ICON"
sed "s|@BINARY@|$PREFIX/agent_tray_demo|" linux/packaging/$APP_ID.desktop > "$DESKTOP"
update-desktop-database "$DATA/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$DATA/icons/hicolor" 2>/dev/null || true

if [[ "${1:-}" == "--autostart" ]]; then
  mkdir -p "$(dirname "$AUTOSTART")"
  cp "$DESKTOP" "$AUTOSTART"
fi

echo "Installed to $PREFIX"
echo "Start it from the app grid (\"Another\") or run: agent-tray-demo"
