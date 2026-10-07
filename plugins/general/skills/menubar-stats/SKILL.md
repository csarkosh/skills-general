---
name: menubar-stats
description: Use when the user wants CPU, GPU, RAM, disk space or temperature shown in the macOS menu bar, is setting up a new Mac's menu bar, wants the disk's free space or readable, de-duplicated temperatures in the menu bar, wants MacStats installed, or wants menu bar items reordered, grouped or kept left-most (another app's icon splitting them, an icon that must stay put).
---

# Menu bar stats on a Mac

This skill reproduces one layout, left-most in the menu bar and in this order:

| CPU | GPU | RAM | Temp | Disk |
|---|---|---|---|---|
| `CPU` over `12%` (usage) | `GPU` over `84%` (utilization) | `RAM` over `89%` (memory in use) | `Temp` over `185°` (the hottest part; soft red while that part is red) | `Disk free` over `75 GB` (free space, whole GB, as Finder counts it) |

All five come from **MacStats** ([github.com/csarkosh/app-macstats](https://github.com/csarkosh/app-macstats)),
a small Swift app that draws them like the Stats app's "mini" widgets, keeps each at one width so
the items beside them never shift, updates every second, and drops a panel down from each. Its
README says what every panel shows; this skill is about getting it installed and the five items
in their places, with other apps' icons out of the group.

Use `scripts/setup.sh` in this skill's directory rather than writing your own: it holds the
setting names, the order and the traps below. Change the layout by editing the script.

## Run it

```bash
bash <this skill's directory>/scripts/setup.sh                  # install, or repair; safe to rerun
bash <this skill's directory>/scripts/setup.sh --tight-spacing  # the same, and narrow the gap around every menu bar icon
bash <this skill's directory>/scripts/setup.sh --uninstall      # remove MacStats and its login agent
```

It needs one system package, the **Xcode Command Line Tools** (`swiftc` builds MacStats on the
Mac; no Homebrew, Xcode or Developer ID). When they are missing the script stops and prints
`xcode-select --install`, which the user must run themselves at a real terminal and then click
Install. A "Background Items Added" notice for the login agent is information only. Install
nothing the user did not ask for.

The script writes the items' places, then installs MacStats with MacStats' own installer
(`curl -fsSL https://raw.githubusercontent.com/csarkosh/app-macstats/main/install.sh | sh`),
which builds the latest release, puts it in `~/Applications/MacStats.app`, adds the login agent
`sh.csarko.macstats` (`~/Library/LaunchAgents`) and starts it; on a later run the installer
rebuilds only for a new release. Then it prints the menu bar's order. `MACSTATS_INSTALL_ARGS`
passes options to the installer (`--ref main` for the tip of MacStats' main branch, `--force` to
rebuild). It retires what earlier versions of this skill set up: DiskMenu (MacStats' older
Disk-only form), and the `sh.csarko.stats-at-login` agent that kept the Stats app running for the
CPU item (it stops Stats and turns its CPU item off, but leaves the app installed and says how to
remove it; a Stats the script never set up is left alone). It never quits other apps. Zoom takes
its new place only when it restarts, so ask the user whether a call is on, then have them quit
and reopen Zoom, or run `osascript -e 'quit app "zoom.us"'` and then `open -a zoom.us` (macOS may
ask to let the terminal control zoom.us).

## How the order works

macOS keeps each item's place as `NSStatusItem Preferred Position <item name>` in the
**owning app's** defaults. A larger number sits further left. An app reads its own entry only
when it starts, so restart the app after writing it.

| Item | Defaults domain | Name | Value |
|---|---|---|---|
| CPU, GPU, RAM, Temp, Disk | `sh.csarko.MacStats` | `MacStatsCPU`, `MacStatsGPU`, `MacStatsRAM`, `MacStatsTemp`, `MacStatsDisk` | 1300, 1250, 1200, 1150, 1100 |
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
  Recording permission the names may be blank; tell the items apart by width (CPU, GPU and RAM
  about 50, Temp about 52, Disk about 60, Zoom about 32; 10 less each with tighter spacing). It
  prints nothing while an app is in full screen.
- `MacStats --render cpu|gpu|ram|temp|disk out.png` (the binary is
  `~/Applications/MacStats.app/Contents/MacOS/MacStats`) draws that item to a PNG; open the image
  to look at it. `MacStats --version` says which release is installed; `--cpu`, `--gpu`,
  `--memory`, `--sensors`, `--spaces`, `--legend`, `--report` and `--tooltips` print what the
  panels show, and `--show-panel temp,disk` opens panels as clicks would (MacStats' README lists
  them all).

## Common mistakes

| Mistake | What happens |
|---|---|
| `defaults write` of a place while the app runs | An app reads its items' places only when it starts; stop it, write, start it |
| Comparing with `df` | MacStats counts purgeable space as free and uses decimal GB, so it reads higher than `df -h` |
| Too many icons on a notched MacBook | Beside the notch there is about 645 pt, and macOS keeps a margin from it; it hides an item that does not fit without a word (not always the left-most: a Focus icon appearing, or the battery showing its percentage, hid the GPU item), and the order script stops listing it. `setup.sh --tight-spacing` narrows the gap around every icon, for every app (`NSStatusItemSpacing` and `NSStatusItemSelectionPadding` set to 6 under `-currentHost`), which frees about 10 pt an icon: apps take it when they start, the system's icons after logging out and in. Undo it with `defaults -currentHost delete -globalDomain` on both keys. Otherwise, hide icons the user doesn't need. The script warns when fewer than five MacStats items show |
| An item never appears on macOS 26 | Check System Settings › Menu Bar › Allow in the Menu Bar for that app |
