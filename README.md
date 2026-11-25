# DiskHealth

[简体中文](README.zh-CN.md) · [Project website](https://ok-bunny.github.io/DiskHealth/en/) · [Releases](https://github.com/ok-bunny/DiskHealth/releases)

DiskHealth is a read-only menu bar monitor for **Apple silicon Macs running macOS 14 or later**. Click its drive icon to check the health of an internal SSD or an external drive, inspect CPU, memory and swap usage, or show a compact desktop panel. The app interface is in Simplified Chinese.

## Install

1. Download [DiskHealth 1.0.6 for macOS arm64](https://github.com/ok-bunny/DiskHealth/releases/download/v1.0.6/DiskHealth-1.0.6-macOS-arm64.zip).
2. Unzip the archive, move `DiskHealth.app` to Applications and open it.
3. Click the drive icon in the menu bar. Enable **桌面小组件** to show the desktop panel.

The release is ad-hoc signed and has not been notarized by Apple. macOS may ask for approval on first launch. If you trust the release and want to proceed, follow Apple's instructions for the **Open Anyway** option in **System Settings → Privacy & Security**. The app runs as a regular user and needs no third-party tools or drivers. [Apple's guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## What you can monitor

| View | What it shows |
| --- | --- |
| Drive health | SMART status and available readings from NVMe and ATA/SATA drives. Expand a drive to see its model, serial number, firmware and supported counters, such as wear, spare capacity, temperature, power-on hours or sector errors. |
| System resources | System-wide CPU utilization, estimated physical memory in use, and swap used out of the amount macOS has currently allocated. |
| Desktop panel | An expanded view of drives and storage usage, or a compact view with CPU, memory and swap rings. Use the arrow to switch views and the pin to keep the panel above other windows. Its position, view and pin settings persist. |

DiskHealth takes an initial reading when it starts. Both automatic refresh switches default to off. **磁盘自动刷新** controls SMART and storage readings at intervals of 10 seconds, 30 seconds, 1 minute, 5 minutes or 1 hour. The separate resource switch samples CPU, memory and swap every 2 seconds. You can also refresh either group once.

SMART coverage depends on the drive and its enclosure. Some USB bridges expose only identification data or an overall status. A missing reading is shown as a dash, and insufficient evidence for a health rating is shown as **未知** (unknown). Capacity figures cover visible local APFS and HFS+ volumes. APFS volumes sharing a container are grouped so their space is counted once.

## Local data and appearance

The app reads SMART and device information through IOKit, CPU and memory counters through Mach, and swap through `vm.swapusage`. Monitoring and health checks run on your Mac. The app does not send drive identifiers, readings or wallpaper to a server. Refresh settings and desktop panel preferences are saved locally.

The panel can sample the brightness of a thumbnail of the local static wallpaper behind it. If the wallpaper is dynamic or unavailable, the panel follows the system appearance. It uses native Liquid Glass on macOS 26.4 or later and a frosted AppKit material on earlier supported systems. The expand/collapse transition respects Reduce Motion.

## Build from source

Use Apple’s Xcode or Command Line Tools with Swift, Clang and the **macOS 26 SDK or newer**. The SDK must include AppKit's `NSGlassEffectView` declaration. The resulting arm64 app targets macOS 14 or later.

```sh
git clone https://github.com/ok-bunny/DiskHealth.git
cd DiskHealth/app
./build.sh
open build/DiskHealth.app
```

The script compiles the Swift app and its C bridge, creates an ad-hoc signature and verifies the bundle. The [probe sources](probe/) are optional standalone diagnostics for NVMe and ATA SMART, with an experimental SAT pass-through probe. The app build uses the [IOKit bridge](app/Sources/smart_bridge.c) directly.

## License

Copyright © 2026 DiskHealth contributors. Licensed under the GNU General Public License, version 3 only (`GPL-3.0-only`). [License text](LICENSE)
