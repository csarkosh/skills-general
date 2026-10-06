#!/bin/bash
# Sets up the menu bar stats group on a Mac, left-most in this order: CPU, GPU, RAM
# and the CPU and GPU temperatures (the Stats app), then Disk used/total (DiskMenu,
# built here). Safe to run again: it rewrites the same settings.
#
#   bash setup.sh              # install or repair
#   bash setup.sh --uninstall  # remove DiskMenu and the login agents (Stats stays)
#
# Stops with the command to run when Homebrew or the Xcode Command Line Tools are
# missing; both need the user at a real terminal (a password or a dialog).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/DiskMenu.app"
AGENTS="$HOME/Library/LaunchAgents"
DISK_AGENT="$AGENTS/sh.csarko.diskmenu.plist"
STATS_AGENT="$AGENTS/sh.csarko.stats-at-login.plist"
STATS=eu.exelban.Stats
POS="NSStatusItem Preferred Position"

say() { printf '%s\n' "$*"; }
fail() { printf 'setup.sh: %s\n' "$*" >&2; exit 1; }

# A signal, not AppleScript's quit, so macOS never asks to let the terminal control the app.
stop_app() { # stop_app <process name>
  pkill -x "$1" || return 0
  for _ in $(seq 20); do pgrep -xq "$1" || return 0; sleep 0.5; done
  pkill -9 -x "$1" || true
}

# A login agent that starts an app only when it is not running. Stats treats being
# opened again while it runs as a request for its Settings window.
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

if [ "${1:-}" = --uninstall ]; then
  for agent in "$DISK_AGENT" "$STATS_AGENT"; do
    launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
    rm -f "$agent"
  done
  stop_app DiskMenu
  rm -rf "$APP"
  say "Removed DiskMenu and the two login agents. Stats is still installed; its Disk module stays off"
  say "until you turn it on in Stats' settings."
  exit 0
fi

# 1. System packages. Homebrew's installer also installs the Command Line Tools.
BREW="$(command -v brew || true)"
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -z "$BREW" ] && [ -x "$candidate" ]; then BREW="$candidate"; fi
done
if [ -z "$BREW" ]; then
  fail "Homebrew is not installed. In Terminal (it asks for your password), run:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
then follow its 'Next steps' to put brew on your PATH, and run this script again."
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  fail "the Xcode Command Line Tools (swiftc, to build DiskMenu) are not installed. Run:
  xcode-select --install
click Install in the dialog, wait for it to finish, and run this script again."
fi
if [ ! -d /Applications/Stats.app ]; then
  say "Installing Stats (github.com/exelban/stats) with Homebrew..."
  "$BREW" install --cask stats
fi
[ "$(uname -m)" = arm64 ] || say "Note: tested on Apple silicon; on an Intel Mac the temperature sensors may be named differently."

# 2. Stats: CPU, GPU and RAM as mini widgets (small label over a value), the CPU and
# GPU temperatures, and nothing else. Stats reads its settings only when it starts,
# so stop it, write them, and start it again.
stop_app Stats
for module in CPU GPU RAM; do
  defaults write "$STATS" "${module}_state" -bool true
  defaults write "$STATS" "${module}_widget" -string mini
done
defaults write "$STATS" Sensors_state -bool true
defaults write "$STATS" Sensors_widget -string sensors
defaults write "$STATS" "sensor_Hottest CPU" -bool true
defaults write "$STATS" "sensor_Hottest GPU" -bool true
for module in Disk Network Battery Bluetooth Clock; do
  defaults write "$STATS" "${module}_state" -bool false
done
# Skip Stats' first-run window: its preset page overwrites the modules chosen above.
defaults write "$STATS" setupProcess -bool true
# Keep each item's place when a module is switched off and on again.
defaults write "$STATS" keep_menubar_positions -bool true

# 3. The order. macOS keeps each item's place as "NSStatusItem Preferred Position
# <name>" in the owning app's settings; a larger number sits further left.
defaults write "$STATS" "$POS CPU_mini" -float 1300
defaults write "$STATS" "$POS GPU_mini" -float 1250
defaults write "$STATS" "$POS RAM_mini" -float 1200
defaults write "$STATS" "$POS Sensors_sensors" -float 1150
defaults write sh.csarko.DiskMenu "$POS DiskMenu" -float 1100
# Zoom never names its item, so it is "Item-0". Without a saved place it lands
# wherever it fits, often inside the group. It reads this when it next starts.
ZOOM_NOTE=""
if [ -d /Applications/zoom.us.app ] || [ -d "$HOME/Applications/zoom.us.app" ]; then
  defaults write us.zoom.xos "$POS Item-0" -float 450
  pgrep -xq zoom.us && ZOOM_NOTE="Zoom is running: if its icon (Item-0) is listed before DiskMenu, quit and reopen Zoom to move it out of the group."
fi

# 4. DiskMenu: build it into ~/Applications.
say "Building DiskMenu if its source changed..."
stop_app DiskMenu
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>sh.csarko.DiskMenu</string>
  <key>CFBundleName</key><string>DiskMenu</string>
  <key>CFBundleExecutable</key><string>DiskMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF
# Rebuild only when the source changed: a rebuild gives the app a new signature, which
# resets any permission macOS has granted it.
SOURCE_HASH="$(shasum -a 256 "$DIR/diskmenu.swift" | cut -d' ' -f1)"
BUILT_HASH="$APP/Contents/Resources/source.sha256"
if [ -x "$APP/Contents/MacOS/DiskMenu" ] && [ "$(cat "$BUILT_HASH" 2>/dev/null)" = "$SOURCE_HASH" ]; then
  say "DiskMenu is up to date."
else
  xcrun swiftc -O "$DIR/diskmenu.swift" -o "$APP/Contents/MacOS/DiskMenu"
  mkdir -p "$APP/Contents/Resources"
  printf '%s\n' "$SOURCE_HASH" > "$BUILT_HASH"
  codesign --force --sign - "$APP" 2>/dev/null
fi

# 5. Start both now and at every login. The Stats agent waits, so that Stats' own
# "Start at login", if it is on, starts it first.
open -a /Applications/Stats.app
mkdir -p "$AGENTS"
login_agent "$STATS_AGENT" sh.csarko.stats-at-login "sleep 5; pgrep -xq Stats || open -a /Applications/Stats.app"
login_agent "$DISK_AGENT" sh.csarko.diskmenu "pgrep -xq DiskMenu || open -a '$APP'"

say "Waiting for the menu bar to settle..."
sleep 8
say "Menu bar, left to right (x, width, owner, item):"
xcrun swift "$DIR/menubar-order.swift" || say "(could not list the menu bar items)"
say ""
say "Expected first: CPU_mini, GPU_mini, RAM_mini, Sensors_sensors, DiskMenu (widths about 47, 47, 47, 44, 100)."
say "On the first launch macOS may ask whether to open Stats, an app downloaded from the internet: click Open."
[ -z "$ZOOM_NOTE" ] || say "$ZOOM_NOTE"
