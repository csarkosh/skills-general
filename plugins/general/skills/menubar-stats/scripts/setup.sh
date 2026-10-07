#!/bin/bash
# Sets up the menu bar stats group on a Mac, left-most in this order: CPU, GPU, RAM,
# Temp and Disk, all drawn by MacStats (github.com/csarkosh/app-macstats), which this
# script installs with MacStats' own installer. Safe to run again: it rewrites the same
# settings, and the installer rebuilds only for a new release. It also retires what
# earlier versions set up: DiskMenu (MacStats' older Disk-only form) and the login
# agent that started the Stats app for the CPU item.
#
#   bash setup.sh                  # install or repair
#   bash setup.sh --tight-spacing  # also narrow the gap around every menu bar icon
#   bash setup.sh --uninstall      # remove MacStats and its login agent
#
# MACSTATS_INSTALL_ARGS passes options to the installer: "--ref main" for the tip of
# MacStats' main branch, "--version v1.2.0" for a particular release, "--force" to
# rebuild. Stops with the command to run when the Xcode Command Line Tools are
# missing; they need the user at a real terminal (a dialog).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="https://raw.githubusercontent.com/csarkosh/app-macstats/main/install.sh"
APP="$HOME/Applications/MacStats.app"
AGENTS="$HOME/Library/LaunchAgents"
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

remove_agent() { # remove_agent <plist path>
  launchctl bootout "gui/$(id -u)" "$1" 2>/dev/null || true
  rm -f "$1"
}

# MacStats' installer, from its repository, with any options the user passed.
install_macstats() { # install_macstats [installer options]
  curl -fsSL "$INSTALLER" | sh -s -- "$@"
}

[ "$(uname -s)" = Darwin ] || fail "this sets up the macOS menu bar; it runs only on macOS."

TIGHT=0
[ "${1:-}" = --tight-spacing ] && TIGHT=1

if [ "${1:-}" = --uninstall ]; then
  for agent in "$OLD_AGENT" "$STATS_AGENT"; do remove_agent "$agent"; done
  stop_app DiskMenu
  rm -rf "$OLD_APP"
  install_macstats --uninstall
  exit 0
fi

# 1. The one system package: the Command Line Tools, for swiftc. The installer checks
# too; checking here first keeps its message from arriving halfway through.
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

# 2b. Only with --tight-spacing: narrow the gap macOS leaves around every menu bar icon,
# for every app (a hidden system setting), so the group fits beside a MacBook's notch,
# where macOS hides whatever does not fit without a word. Apps read it when they start;
# the system's own icons once the user logs out and in.
SPACING_NOTE=""
if [ "$TIGHT" = 1 ]; then
  defaults -currentHost write -globalDomain NSStatusItemSpacing -int 6
  defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 6
  SPACING_NOTE="Menu bar icons sit closer together now; log out and back in for the system's own icons to follow. To undo it: defaults -currentHost delete -globalDomain NSStatusItemSpacing; defaults -currentHost delete -globalDomain NSStatusItemSelectionPadding"
fi

# 3. The order. macOS keeps each item's place as "NSStatusItem Preferred Position
# <name>" in the owning app's settings; a larger number sits further left. MacStats
# reads these when it starts, so they go in before the installer starts it.
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

# 4. Retire DiskMenu if this Mac has it, then install MacStats (or update it to the
# latest release) with its own installer, which builds it, puts it in ~/Applications
# and adds the login agent sh.csarko.macstats.
if [ -e "$OLD_APP" ] || [ -e "$OLD_AGENT" ]; then
  say "Replacing DiskMenu with MacStats..."
  remove_agent "$OLD_AGENT"
  stop_app DiskMenu
  rm -rf "$OLD_APP"
  defaults delete sh.csarko.DiskMenu >/dev/null 2>&1 || true
fi
# shellcheck disable=SC2086
install_macstats ${MACSTATS_INSTALL_ARGS:-}
# A running MacStats takes new places only when it starts again.
if pgrep -xq MacStats; then
  stop_app MacStats
  open -a "$APP"
fi

# 5. What the menu bar shows now.
say "Waiting for the menu bar to settle..."
sleep 8
say "Menu bar, left to right (x, width, owner, item):"
ORDER="$(xcrun swift "$DIR/menubar-order.swift" 2>/dev/null || true)"
[ -n "$ORDER" ] && say "$ORDER" || say "(could not list the menu bar items)"
say ""
say "Expected first: MacStatsCPU, MacStatsGPU, MacStatsRAM, MacStatsTemp, MacStatsDisk (widths about 50, 50, 50, 52, 60, or 10 less each with tighter spacing)."
# The names show only with Screen Recording permission; count only when they do.
if printf '%s\n' "$ORDER" | grep -q MacStats; then
  SHOWN="$(printf '%s\n' "$ORDER" | grep -c ' MacStats' || true)"
  if [ "$SHOWN" -lt 5 ]; then
    say "Only $SHOWN of MacStats' 5 items fit: beside a MacBook's notch macOS hides what does not fit."
    [ "$TIGHT" = 1 ] || say "Run 'bash setup.sh --tight-spacing' to narrow the gap around every icon, or hide icons you don't need in System Settings > Menu Bar."
  fi
fi
[ -z "$SPACING_NOTE" ] || say "$SPACING_NOTE"
[ -z "$ZOOM_NOTE" ] || say "$ZOOM_NOTE"
[ -z "$STATS_NOTE" ] || say "$STATS_NOTE"
