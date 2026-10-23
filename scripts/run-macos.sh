#!/usr/bin/env bash
# Downloads a CI build of the demo for macOS, installs it and starts it.
#
#   curl -fsSL https://raw.githubusercontent.com/vymalo/frb-tray-spike/main/scripts/run-macos.sh | bash
#   scripts/run-macos.sh [--build N] [--dir DIR] [--logs]
#   scripts/run-macos.sh --uninstall [--dir DIR]
#
#   --build N     build N from the releases page (default: the latest build)
#   --dir DIR     where to put agent_tray_demo.app (default: ~/Applications)
#   --logs        run in this terminal and show the app's output; Ctrl-C quits
#   --uninstall   quit the app and remove it and its data
set -euo pipefail

repo=vymalo/frb-tray-spike
asset=agent_tray_demo-macos.zip
build=""
dir="$HOME/Applications"
logs=0
uninstall=0

while [ $# -gt 0 ]; do
  case "$1" in
    --build) build="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --logs) logs=1; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != Darwin ]; then
  echo "This script is for macOS. On Linux use run-linux.sh." >&2
  exit 1
fi

app="$dir/agent_tray_demo.app"
# The app is sandboxed, so macOS keeps its data in a container of its own.
container="$HOME/Library/Containers/dev.demo.agentTrayDemo"

if [ "$uninstall" = 1 ]; then
  pkill -x agent_tray_demo 2>/dev/null && sleep 1 || true
  rm -rf "$app" "$container"
  echo "Removed $app and $container"
  exit 0
fi

if [ -n "$build" ]; then
  url="https://github.com/$repo/releases/download/build-$build/$asset"
else
  url="https://github.com/$repo/releases/latest/download/$asset"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
curl -fL --progress-bar -o "$tmp/$asset" "$url"

# A copy that's still running would keep its tray icon and old code.
pkill -x agent_tray_demo 2>/dev/null && sleep 1 || true

mkdir -p "$dir"
rm -rf "$app"
ditto -x -k "$tmp/$asset" "$dir"
# The app isn't signed. Browsers mark downloads as quarantined, which makes
# Gatekeeper refuse to open it; clear that in case the zip was fetched that way.
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
echo "Installed $app"

if [ "$logs" = 1 ]; then
  echo "Running with logs. Look for the icon in the menu bar; Ctrl-C quits."
  exec "$app/Contents/MacOS/agent_tray_demo"
fi
open "$app"
echo "Running. Look for the icon in the menu bar: click it, or press Option-Space."
echo "The app has no Dock icon. Quit it from the popover's Quit button."
