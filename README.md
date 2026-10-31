# Mac Metrics

A small, native macOS menu bar monitor focused on CPU, GPU, and RAM.

## What it does

- Shows CPU, GPU, and RAM percentages as three independent native menu bar buttons with separate click highlights.
- Click CPU to see every core’s utilization, grouped by the hardware’s Performance/Efficiency identifiers, and a scrollable list of your processes, ordered by CPU usage.
- Click RAM to see a scrollable list of your processes ordered by physical footprint, and current swap usage.
- Force quit a process from either list after confirming the action; macOS may prevent quitting protected processes.
- Click GPU for the available aggregate GPU reading and its process-visibility note.
- Open Settings from the bottom of a metric panel to control launch at login, visible menu bar metrics, and the refresh interval.
- Samples lightweight system totals at the selected interval; process rankings are read only while a metric panel is open.
- Uses Swift, AppKit, SwiftUI, and system frameworks only. No analytics, network access, or third-party dependencies.
- Uses native Liquid Glass on macOS 26 and newer, with a system material fallback on macOS 14 and 15.

Each metric has its own saved menu bar position. macOS controls ordering; Command-drag the buttons to arrange them. Independent system items cannot be locked into an indivisible group through the public status-item API.

CPU and RAM lists support searching by process name or PID. Values keep updating while you scroll, but row order stays fixed until you return to the top; processes that exit while browsing are marked Ended so they cannot shift the visible rows. Process scanning runs away from the UI thread, visible-row icons load after scrolling settles, and rows align when scrolling stops. Subtle hover and row transitions respect Reduce Motion; popovers still open without animation.

## Percentage conventions

- System CPU and each core use busy tick deltas divided by total tick deltas (0–100%).
- Process CPU uses Mach absolute-time deltas converted to nanoseconds, divided by monotonic elapsed time and the number of logical cores. Values are a percentage of total CPU capacity; one fully occupied core on an 8-core Mac is 12.5%.
- RAM usage is non-purgeable anonymous app pages plus wired and compressed storage, divided by physical RAM. Reclaimable file cache is excluded.
- Each process’s RAM percentage is its physical footprint divided by physical RAM. Swap is disk-backed memory and is shown separately as used / allocated swap.
- Core classifications come from the machine’s CPU registry identifiers. If those are unavailable, cores appear in a generic group.

## GPU data limits

macOS does not offer a stable public API for per-process GPU utilization. Aggregate GPU readings are read from the graphics driver's IORegistry performance statistics when that key is exposed. The GPU menu bar item shows an em dash when the driver does not expose a recognized utilization value. The GPU popover explains the per-process limitation instead of guessing a top-five list.

## Build and install

Requirements: macOS 14 or newer and Xcode Command Line Tools (or Xcode).

```sh
git clone https://github.com/ziyadvf/mac-metrics.git
cd mac-metrics
Scripts/build.sh
open dist/MacMetrics.app
```

To install for the current user, run `Scripts/install.sh`. It copies the app into `~/Applications` and launches it. The app is an ad-hoc signed local build until you sign it with your own Apple Developer ID. Launch at login is off by default and can be enabled in Settings.

The app icon is included in `Resources/AppIcon.icns`. To regenerate it after changing the vector artwork, run `Scripts/generate-icon.sh`.

## Footprint choices

- No polling of detailed process data until CPU or RAM is opened.
- Two-second refresh cadence keeps the menu-bar display responsive without high-frequency sampling.
- The app makes no network requests and includes no external libraries or embedded web view.
- The executable is compiled in release mode by `Scripts/build.sh`.
