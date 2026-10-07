#!/bin/bash
# Sets up the menu bar stats group on a Mac, left-most in this order: CPU, GPU, RAM,
# Temp and Disk, all drawn by MacStats, built here from macstats/. Safe to run again:
# it rewrites the same settings. It also retires what earlier versions set up: DiskMenu
# (MacStats' older Disk-only form) and the login agent that started the Stats app.
#
#   bash setup.sh              # install or repair
#   bash setup.sh --uninstall  # remove MacStats and its login agent
#
# Stops with the command to run when the Xcode Command Line Tools are missing; they
# need the user at a real terminal (a dialog).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/MacStats.app"
AGENTS="$HOME/Library/LaunchAgents"
MACSTATS_AGENT="$AGENTS/sh.csarko.macstats.plist"
STATS_AGENT="$AGENTS/sh.csarko.stats-at-login.plist"
OLD_APP="$HOME/Applications/DiskMenu.app"
OLD_AGENT="$AGENTS/sh.csarko.diskmenu.plist"
POS="NSStatusItem Preferred Position"

say() { printf '%s\n' "$*"; }
fail() { printf 'setup.sh: %s\n' "$*" >&2; exit 1; }

# A signal, not AppleScript's quit, so macOS never asks to let the terminal control the app.
stop_app() { # stop_app <process name>
  pkill -x "$1" || return 0
  for _ in $(seq 20); do pgrep -xq "$1" || return 0; sleep 0.5; done
  pkill -9 -x "$1" || true
}

# A login agent that starts an app only when it is not running.
login_agent() { # login_agent <plist path> <label> <shell command>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$2</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>$3</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  plutil -lint -s "$1"
  launchctl bootout "gui/$(id -u)" "$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$1"
}

[ "$(uname -s)" = Darwin ] || fail "this sets up the macOS menu bar; it runs only on macOS."

remove_agent() { # remove_agent <plist path>
  launchctl bootout "gui/$(id -u)" "$1" 2>/dev/null || true
  rm -f "$1"
}

if [ "${1:-}" = --uninstall ]; then
  for agent in "$MACSTATS_AGENT" "$OLD_AGENT" "$STATS_AGENT"; do remove_agent "$agent"; done
  stop_app MacStats
  stop_app DiskMenu
  rm -rf "$APP" "$OLD_APP"
  say "Removed MacStats and its login agent."
  exit 0
fi

# 1. System packages: only the Command Line Tools, for swiftc.
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  fail "the Xcode Command Line Tools (swiftc, to build MacStats) are not installed. Run:
  xcode-select --install
click Install in the dialog, wait for it to finish, and run this script again."
fi
[ "$(uname -m)" = arm64 ] || say "Note: tested on Apple silicon; an Intel Mac's sensors come from the same catalog but are untested."

# 2. Earlier versions showed the CPU with the Stats app and started it at login. Stop
# that agent and Stats, and turn Stats' CPU item off, so a Stats opened by hand does
# not add a second CPU. Stats itself stays installed: removing an app is the user's
# call. A Stats this script never set up is left alone.
STATS_NOTE=""
if [ -e "$STATS_AGENT" ]; then
  say "Retiring the Stats app's CPU item (MacStats shows the CPU now)..."
  remove_agent "$STATS_AGENT"
  stop_app Stats
  defaults write eu.exelban.Stats CPU_state -bool false
  STATS_NOTE="Stats is no longer used. It is still installed: remove it with 'brew uninstall --cask stats', or drag it from Applications to the Trash."
fi

# 3. The order. macOS keeps each item's place as "NSStatusItem Preferred Position
# <name>" in the owning app's settings; a larger number sits further left.
defaults write sh.csarko.MacStats "$POS MacStatsCPU" -float 1300
defaults write sh.csarko.MacStats "$POS MacStatsGPU" -float 1250
defaults write sh.csarko.MacStats "$POS MacStatsRAM" -float 1200
defaults write sh.csarko.MacStats "$POS MacStatsTemp" -float 1150
defaults write sh.csarko.MacStats "$POS MacStatsDisk" -float 1100
# Zoom never names its item, so it is "Item-0". Without a saved place it lands
# wherever it fits, often inside the group. It reads this when it next starts.
ZOOM_NOTE=""
if [ -d /Applications/zoom.us.app ] || [ -d "$HOME/Applications/zoom.us.app" ]; then
  defaults write us.zoom.xos "$POS Item-0" -float 450
  pgrep -xq zoom.us && ZOOM_NOTE="Zoom is running: if its icon (Item-0) is listed before MacStatsDisk, quit and reopen Zoom to move it out of the group."
fi

# 4. MacStats: retire DiskMenu if this Mac has it, then build into ~/Applications.
if [ -e "$OLD_APP" ] || [ -e "$OLD_AGENT" ]; then
  say "Replacing DiskMenu with MacStats..."
  remove_agent "$OLD_AGENT"
  stop_app DiskMenu
  rm -rf "$OLD_APP"
  defaults delete sh.csarko.DiskMenu >/dev/null 2>&1 || true
fi
say "Building MacStats if its source changed..."
stop_app MacStats
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>sh.csarko.MacStats</string>
  <key>CFBundleName</key><string>MacStats</string>
  <key>CFBundleExecutable</key><string>MacStats</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF
# Rebuild only when the source changed: a rebuild gives the app a new signature, which
# resets any permission macOS has granted it.
SOURCE_HASH="$(cat "$DIR"/macstats/*.swift | shasum -a 256 | cut -d' ' -f1)"
BUILT_HASH="$APP/Contents/Resources/source.sha256"
if [ -x "$APP/Contents/MacOS/MacStats" ] && [ "$(cat "$BUILT_HASH" 2>/dev/null)" = "$SOURCE_HASH" ]; then
  say "MacStats is up to date."
else
  xcrun swiftc -O "$DIR"/macstats/*.swift -o "$APP/Contents/MacOS/MacStats"
  mkdir -p "$APP/Contents/Resources"
  printf '%s\n' "$SOURCE_HASH" > "$BUILT_HASH"
  codesign --force --sign - "$APP" 2>/dev/null
fi

# 5. Start MacStats now and at every login.
mkdir -p "$AGENTS"
login_agent "$MACSTATS_AGENT" sh.csarko.macstats "pgrep -xq MacStats || open -a '$APP'"

say "Waiting for the menu bar to settle..."
sleep 8
say "Menu bar, left to right (x, width, owner, item):"
xcrun swift "$DIR/menubar-order.swift" || say "(could not list the menu bar items)"
say ""
say "Expected first: MacStatsCPU, MacStatsGPU, MacStatsRAM, MacStatsTemp, MacStatsDisk (widths about 50, 50, 50, 52, 100)."
[ -z "$ZOOM_NOTE" ] || say "$ZOOM_NOTE"
[ -z "$STATS_NOTE" ] || say "$STATS_NOTE"
