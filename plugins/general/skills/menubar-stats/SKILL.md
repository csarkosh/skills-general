---
name: menubar-stats
description: Use when the user wants CPU, GPU, RAM, disk space or temperature shown in the macOS menu bar, is setting up a new Mac's menu bar, wants the disk's used and total space (not a percentage) in the menu bar, uses the Stats app (exelban/stats), or wants menu bar items reordered, grouped or kept left-most (another app's icon splitting them, an icon that must stay put).
---

# Menu bar stats on a Mac

This skill reproduces one layout, left-most in the menu bar and in this order:

| CPU | GPU | RAM | Temperature | Disk |
|---|---|---|---|---|
| `CPU` over `12%` | `GPU` over `84%` | `RAM` over `89%` | `153°` over `151°` (CPU, GPU) | `Disk` over `215.9/245.1 GB` (used/total) |

CPU, GPU, RAM and the temperatures come from **Stats** (free, `brew install --cask stats`).
The Disk item is **DiskMenu**, about 100 lines of Swift in `scripts/diskmenu.swift`, built on the
Mac. Stats cannot draw it: its Disk text widget is a single 12pt line with no label, and its
two-line "memory" widget shows free over used (people misread it as used over total).

Use `scripts/setup.sh` in this skill's directory rather than writing your own: it holds the
setting names, the order and the traps below. Change the layout by editing the script.

## Run it

```bash
bash <this skill's directory>/scripts/setup.sh              # install, or repair; safe to rerun
bash <this skill's directory>/scripts/setup.sh --uninstall  # remove DiskMenu and its login agents
```

It needs three system packages. When one is missing it stops and prints the command, and
the user must run that command themselves at a real terminal:

| Package | Why | Install (the user's hands) |
|---|---|---|
| Homebrew | installs Stats | the official one-liner from brew.sh, which asks for the user's password; its "Next steps" put `brew` on the PATH |
| Xcode Command Line Tools | `swiftc` builds DiskMenu | `xcode-select --install`, then click Install (Homebrew's installer usually installs them already) |
| Stats | CPU, GPU, RAM, temperatures | the script runs `brew install --cask stats` itself |

Also for the user: on its first launch macOS may ask whether to open Stats, an app downloaded
from the internet (click Open), and a "Background Items Added" notice for the login agents is
information only. Install nothing the user did not ask for.

The script stops and restarts Stats and DiskMenu, writes their settings, adds login agents
`sh.csarko.stats-at-login` and `sh.csarko.diskmenu` (`~/Library/LaunchAgents`), and then prints
the menu bar's order. It never quits other apps. Zoom takes its new place only when it restarts,
so ask the user whether a call is on, then have them quit and reopen Zoom, or run
`osascript -e 'quit app "zoom.us"'` and then `open -a zoom.us` (macOS may ask to let the terminal
control zoom.us).

## How the order works

macOS keeps each item's place as `NSStatusItem Preferred Position <item name>` in the
**owning app's** defaults. A larger number sits further left. An app reads its own entry only
when it starts, so restart the app after writing it.

| Item | Defaults domain | Name | Value |
|---|---|---|---|
| CPU, GPU, RAM | `eu.exelban.Stats` | `CPU_mini`, `GPU_mini`, `RAM_mini` | 1300, 1250, 1200 |
| Temperatures | `eu.exelban.Stats` | `Sensors_sensors` | 1150 |
| Disk | `sh.csarko.DiskMenu` | `DiskMenu` | 1100 |
| Zoom | `us.zoom.xos` | `Item-0` | 450 (the script writes it only if Zoom is installed) |

An app that never saved a place lands wherever there is room, often inside the group. To fix
another app: find its item name with the order script below (`Item-0` when the app never named
its item), get its domain with `osascript -e 'id of app "Name"'`, write a value under 1100, and
restart that app. ⌘-dragging an icon also saves a place.

## Check it without screenshots

Screenshots and reading the menu bar through System Events need permissions a terminal usually
lacks. Use these instead, then ask the user to glance at the menu bar:

- `swift scripts/menubar-order.swift` prints the status items left to right: x, width, owner,
  name. On macOS 26 every owner is "Control Center" and the names are the ones in the table
  above. The group is unbroken when each x is the previous x plus its width. Without Screen
  Recording permission the names may be blank; tell the items apart by width (CPU, GPU, RAM
  about 47, temperatures about 44, Disk about 100, Zoom about 32). It prints nothing while an
  app is in full screen.
- `~/Applications/DiskMenu.app/Contents/MacOS/DiskMenu --render /tmp/diskmenu.png` draws the
  Disk item to a PNG; open the image to look at it.

## Common mistakes

| Mistake | What happens |
|---|---|
| `defaults write` while Stats is running | Stats reads its settings only when it starts; stop it, write, start it |
| `open -a Stats` while Stats is running | Stats opens its Settings window; the login agent checks `pgrep` first |
| Leaving Stats' first-run window on | Its preset page overwrites the chosen modules; the script sets `setupProcess` to skip it |
| Comparing with `df` | Stats and DiskMenu count purgeable space as free and use decimal GB, so they read higher than `df -h` |
| Too many icons on a notched MacBook | macOS hides the left-most items first, so this group is the first to vanish; turn off icons the user doesn't need |
| An item never appears on macOS 26 | Check System Settings › Menu Bar › Allow in the Menu Bar for that app |
| Guessing a Stats setting's name | Read Stats' source for the key. Widgets are `<Module>_widget`, on/off is `<Module>_state`, a temperature sensor shows when `sensor_<name>` is true, and `temperature_units` is `system` (the region's), `celsius` or `fahrenheit` |
