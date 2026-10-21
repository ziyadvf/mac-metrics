# Mac Metrics

A small, native macOS menu bar monitor focused on CPU, GPU, and RAM.

## What it does

- Shows CPU, GPU, and RAM percentages as three independent menu bar items.
- Click CPU to see the five processes with the highest recent CPU usage.
- Click RAM to see the five processes using the most physical memory.
- Force quit a process from either list after confirming the action; macOS may prevent quitting protected processes.
- Click GPU for the available aggregate GPU reading and its process-visibility note.
- Samples lightweight system totals every two seconds; process rankings are read only while a popover is open.
- Uses Swift, AppKit, SwiftUI, and system frameworks only. No analytics, network access, or third-party dependencies.
- Uses native Liquid Glass on macOS 26 and newer, with a system material fallback on macOS 14 and 15.

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

To install for the current user, run `Scripts/install.sh`. It copies the app into `~/Applications` and launches it. The app is an ad-hoc signed local build until you sign it with your own Apple Developer ID. Launch at login is intentionally not enabled by default.

## Footprint choices

- No polling of detailed process data until CPU or RAM is opened.
- Two-second refresh cadence keeps the menu-bar display responsive without high-frequency sampling.
- The app makes no network requests and includes no external libraries or embedded web view.
- The executable is compiled in release mode by `Scripts/build.sh`.
