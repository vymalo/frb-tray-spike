#!/usr/bin/env bash
# Downloads a CI build of the demo for Linux (x64), installs it and starts it.
#
#   curl -fsSL https://raw.githubusercontent.com/vymalo/frb-tray-spike/main/scripts/run-linux.sh | bash
#   scripts/run-linux.sh [--build N] [--dir DIR] [--logs]
#
#   --build N   build N from the releases page (default: the latest build)
#   --dir DIR   where to put the bundle (default: ~/.local/opt/frb-tray-spike)
#   --logs      run in this terminal and show the app's output; Ctrl-C quits
set -euo pipefail

repo=vymalo/frb-tray-spike
asset=agent_tray_demo-linux-x64.tar.gz
build=""
dir="$HOME/.local/opt/frb-tray-spike"
logs=0

while [ $# -gt 0 ]; do
  case "$1" in
    --build) build="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --logs) logs=1; shift ;;
    -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  echo "This build is for x64 Linux. On macOS use run-macos.sh." >&2
  exit 1
fi
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "No desktop session found (DISPLAY and WAYLAND_DISPLAY are unset)." >&2
  exit 1
fi
if ! ldconfig -p 2>/dev/null | grep 'libgtk-3\.so\.0' >/dev/null; then
  echo "GTK 3 is missing. Install it first, e.g. sudo apt install libgtk-3-0" >&2
  exit 1
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
rm -rf "$dir/bundle"
tar -xzf "$tmp/$asset" -C "$dir"
exe="$dir/bundle/agent_tray_demo"
echo "Installed $exe"

# GNOME shows tray icons only through its AppIndicator extension (on by
# default on Ubuntu).
if command -v gnome-extensions >/dev/null &&
   ! gnome-extensions list --enabled 2>/dev/null | grep -i appindicator >/dev/null; then
  echo "Note: GNOME's AppIndicator extension looks disabled, so the tray icon"
  echo "may not show. Enable it with: gnome-extensions enable ubuntu-appindicators@ubuntu.com"
fi

if [ "$logs" = 1 ]; then
  echo "Running with logs. Look for the icon in the top bar; Ctrl-C quits."
  exec "$exe"
fi
log="$dir/agent_tray_demo.log"
nohup "$exe" >"$log" 2>&1 &
pid=$!
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then
  echo "The app exited right away. Its output:" >&2
  cat "$log" >&2
  exit 1
fi
echo "Running (pid $pid). Look for the icon in the top bar and click it."
echo "Quit from the popover's Quit button. Output goes to $log"
