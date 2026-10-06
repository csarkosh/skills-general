---
name: menubar-stats
description: Use when the user wants CPU, GPU, RAM, disk space or temperature shown in the macOS menu bar, is setting up a new Mac's menu bar, wants the disk's used and total space (not a percentage) or readable, de-duplicated temperatures in the menu bar, uses the Stats app (exelban/stats), or wants menu bar items reordered, grouped or kept left-most (another app's icon splitting them, an icon that must stay put).
---

# Menu bar stats on a Mac

This skill reproduces one layout, left-most in the menu bar and in this order:

| CPU | GPU | RAM | Temp | Disk |
|---|---|---|---|---|
| `CPU` over `12%` | `GPU` over `84%` | `RAM` over `89%` | `Temp` over `185°` (the hottest part; soft red while that part is red) | `Disk` over `215.9/245.1 GB` (used/total) |

CPU, GPU and RAM come from **Stats** (free, `brew install --cask stats`). Temp and Disk come from
**MacStats**, a small Swift app in `scripts/macstats/`, built on the Mac. Stats cannot draw them: its
Disk widgets cannot put a label over custom text, and its temperature list repeats every sensor
("CPU efficiency core 1" to "4", "GPU 1" to "8"). Both MacStats items update every second, like
Stats' CPU and GPU, together for under 0.5% of one core, and both drop down a panel styled like
Stats'.
Right-click either for Quit.

Each feature is one file, so a later App Store edition can leave one out (the sandbox forbids the
SMC reads and the disk-wide folder walk): `MenuKit.swift` (the item and the panel's look, shared),
`Temp.swift` with `Sensors.swift`, `SMC.swift` and `SensorCatalog.swift`, `Disk.swift`, and
`Battery.swift` (the battery's charge, for Temp's Power section), and `main.swift` (starts both,
and the command line). `SMC.swift` and `SensorCatalog.swift` are adapted
from Stats (MIT); its licence is `scripts/macstats/LICENSE-stats.txt`.

Use `scripts/setup.sh` in this skill's directory rather than writing your own: it holds the
setting names, the order and the traps below. Change the layout by editing the script.

## Run it

```bash
bash <this skill's directory>/scripts/setup.sh              # install, or repair; safe to rerun
bash <this skill's directory>/scripts/setup.sh --uninstall  # remove MacStats and its login agents
```

It needs three system packages. When one is missing it stops and prints the command, and
the user must run that command themselves at a real terminal:

| Package | Why | Install (the user's hands) |
|---|---|---|
| Homebrew | installs Stats | the official one-liner from brew.sh, which asks for the user's password; its "Next steps" put `brew` on the PATH |
| Xcode Command Line Tools | `swiftc` builds MacStats | `xcode-select --install`, then click Install (Homebrew's installer usually installs them already) |
| Stats | CPU, GPU, RAM | the script runs `brew install --cask stats` itself |

Also for the user: on its first launch macOS may ask whether to open Stats, an app downloaded
from the internet (click Open), and a "Background Items Added" notice for the login agents is
information only. Install nothing the user did not ask for.

The script stops and restarts Stats and MacStats, writes their settings (Stats' Sensors and Disk
modules off), adds login agents `sh.csarko.stats-at-login` and `sh.csarko.macstats`
(`~/Library/LaunchAgents`), replaces DiskMenu (MacStats' older Disk-only form) if the Mac has it,
and then prints the menu bar's order. It rebuilds MacStats only when its source changed. It never
quits other apps. Zoom takes its new place only when it restarts, so ask the user whether a call
is on, then have them quit and reopen Zoom, or run `osascript -e 'quit app "zoom.us"'` and then
`open -a zoom.us` (macOS may ask to let the terminal control zoom.us).

## How the order works

macOS keeps each item's place as `NSStatusItem Preferred Position <item name>` in the
**owning app's** defaults. A larger number sits further left. An app reads its own entry only
when it starts, so restart the app after writing it.

| Item | Defaults domain | Name | Value |
|---|---|---|---|
| CPU, GPU, RAM | `eu.exelban.Stats` | `CPU_mini`, `GPU_mini`, `RAM_mini` | 1300, 1250, 1200 |
| Temp, Disk | `sh.csarko.MacStats` | `MacStatsTemp`, `MacStatsDisk` | 1150, 1100 |
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
  about 47, Temp about 45, Disk about 100, Zoom about 32). It prints nothing while an app is in
  full screen.
- `MacStats --render temp|disk out.png` (the binary is `~/Applications/MacStats.app/Contents/MacOS/MacStats`)
  draws that item to a PNG; open the image to look at it.

From a terminal, `MacStats --sensors` prints the Temp panel, `--weigh 49.8 53.0 …` prints those
temperatures' weighted value, `--spaces` the disk's five volumes, `--legend` the Disk panel's
Spaces rows in order, `--report` its folders (add a folder to list only it, and `--min-mb N` to
change the cut-off), and `--show-panel temp|disk` starts it with that panel open.

## The Temp panel

Two gauges on top, drawn like Stats' RAM pressure gauge (three equal green, yellow and red arcs
and a blue needle, which here moves along its band): the hottest part on that part's own limits
("Hot · 185°F" over its name), and power use ("Normal · 9 W" over the battery time left at that
rate, or "on charger"). Power use is Total in watts, in tiers from the Mac's own figures in
`Temp.swift`: the M4 MacBook Air idles at 0.7–3.6 W (Apple's ENERGY STAR filing), sustains 8–9 W
on its chip and bursts to 20–23 W, and peaks near 31 W, its 30 W charger's size (Notebookcheck,
LaptopMedia), so normal is below 10 W, moderate below 20 W and high from 20 W. Other chip classes
get scaled estimates. `MacStats --power-level <W>` prints a tier.

Then three sections, each only when the Mac has such sensors: Temperature, Power and Fans. The sensors
are the SMC keys in `SensorCatalog.swift` that this chip answers (generated from Stats' list, so new
chips arrive with a Stats update).

**Temperature is one row per part of the Mac**, hottest first: numbered sensors share a row
("CPU performance core 1" to "8" are "CPU performance cores", "GPU 1" to "8" are "GPU",
"Airport" is "Wi-Fi"). A row's value leans toward its hottest sensor: each reading is weighted
by e^((t − hottest) / 3 °C), so the hottest counts fully, one 3 °C cooler about 37% and one
6 °C cooler about 14%. The tooltip gives the sensor count and range and the row's limits.
Squares turn yellow and red at limits set per part in `Temp.swift`, because parts differ: chip
parts (CPU, GPU, machine-learning engine, memory) yellow from 85 °C and red from 100 °C (they run at
60–85 °C under load and throttle from about 90–100 °C); the battery from 35 °C and 40 °C (Apple's
range is 10–35 °C, and heat above 40 °C wears it); the SSD from 50 °C and 70 °C (flash is rated
to about 70 °C); anything else from 60 °C and 80 °C. `MacStats --heat "<row>" <°C>` prints a
row's colour, and a test pins every limit. The menu bar shows the top row's temperature, in °F
where the Mac's region uses US units and °C elsewhere, tinted soft red while that row is red.

**Power is Stats' Voltage, Current and Power sections in plain words**, each row with a tooltip
saying what it is: Total (`PSTR`, everything the Mac uses), Battery (`PPBR`, power out of the
battery), Charger (`PDTR` in watts, with `VD0R` volts and `ID0R` amps in its tooltip; shown only
while a charger is connected) and Internal supply (`VP0R`, the main supply line, near 12 V). Any
other power, voltage or current sensor follows under Stats' name for it. Battery left comes last
(`26.2/53.5 Wh (49%)`: what remains of what a full charge holds now, from the `AppleSmartBattery`
registry entry in `Battery.swift`). Its mAh become Wh at the cells' rated 3.87 V, not the live
voltage, which would swing with charging; that matches Apple's ratings (4,629 mAh is the M4
MacBook Air's 53.8 Wh). The percentage is the battery icon's, and the tooltip adds the capacity
when new and the charge cycles. Fans lists each fan in RPM.

Reading the SMC needs no permission and causes no privacy prompt.

## The Disk panel

Its Spaces section is laid out like Stats' RAM details: Used, a line bar split by colour, then a
coloured row for each part of the bar, biggest first with Free always last (the bar follows the
same order): macOS system (orange), update/boot (yellow), recovery (purple), swap (pink), my
apps / files (blue), other (brown: APFS bookkeeping and any extra volume), Purgeable (teal) and
Free (grey). The rows and the bar come from one list in `Disk.swift`, `spaceLegend`, so every
row has a colour and the rows add up to Used.

The volumes are the startup disk's APFS volumes by role, from `diskutil apfs list`: System,
Preboot plus Update, Recovery, VM and Data; Used and Free are the container's. Purgeable is space
macOS frees on its own: the panel's volumes count it as used, the menu bar (like Finder) as free.
Below, my apps / files is broken down into folders three levels deep (100 MB and over, biggest
first; an app is one row), measured on the Data volume (`/System/Volumes/Data`) by allocated
blocks like `du -x`. That takes about a minute, so the panel reuses a measurement for 10 minutes,
and while it measures again it keeps showing the last one ("Updating… last measured at …"). The
last measurement is saved to `~/Library/Caches/sh.csarko.MacStats/folders.json`, so after a
restart the panel opens with it instead of an empty list.
The header's arrow measures again, its drive icon opens Storage settings, and double-clicking a
folder shows it in Finder.

**Privacy.** MacStats never opens the folders macOS guards with a permission prompt or that hold
private data: Desktop, Documents, Downloads, Music, Movies, iCloud Drive and cloud-storage folders,
other apps' data (`Library/Containers`, `Library/Group Containers`), Mail, Messages, Safari,
Contacts, Calendars, and the Photos, Music and TV libraries. No app can learn a folder's size
without reading inside it, so these show as **private** with no size, and a folder holding one
shows **≥** (at least). macOS refuses a few system folders and the Trash silently, without a prompt;
those show **no access**. Finder's Get Info shows a private folder's size.

To check that a change prompts for nothing, run the installed app as itself (`open -n -W -a
~/Applications/MacStats.app --args --report`) and read which privacy services it asked for:
`/usr/bin/log show --last 5m --info --predicate 'process == "tccd" AND eventMessage CONTAINS
"Sub:{sh.csarko.MacStats}"'` (in zsh, `log` alone is a builtin). Only
`kTCCServiceSystemPolicyAllFiles`, which never prompts, may appear while it measures. Listing inside
`~/Music` or `~/Movies` alone triggers the media library prompt, so those stay private whole.

## Common mistakes

| Mistake | What happens |
|---|---|
| `defaults write` while Stats is running | Stats reads its settings only when it starts; stop it, write, start it |
| `open -a Stats` while Stats is running | Stats opens its Settings window; the login agent checks `pgrep` first |
| Leaving Stats' first-run window on | Its preset page overwrites the chosen modules; the script sets `setupProcess` to skip it |
| Comparing with `df` | Stats and MacStats count purgeable space as free and use decimal GB, so they read higher than `df -h` |
| Too many icons on a notched MacBook | macOS hides the left-most items first, so this group is the first to vanish; turn off icons the user doesn't need |
| An item never appears on macOS 26 | Check System Settings › Menu Bar › Allow in the Menu Bar for that app |
| Guessing a Stats setting's name | Read Stats' source for the key. Widgets are `<Module>_widget`, on/off is `<Module>_state` |
