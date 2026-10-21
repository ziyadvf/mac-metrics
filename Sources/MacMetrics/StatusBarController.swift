import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store = MetricsStore()
    private var items: [Metric: NSStatusItem] = [:]
    private var popovers: [Metric: NSPopover] = [:]
    private var refreshTimer: Timer?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    override init() {
        super.init()
        for metric in Metric.allCases {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.tag = Metric.allCases.firstIndex(of: metric) ?? 0
            items[metric] = item

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentSize = NSSize(width: 340, height: metric == .gpu ? 250 : 410)
            popover.contentViewController = NSHostingController(rootView: MetricPopover(metric: metric, store: store))
            popovers[metric] = popover
        }
        refreshLabels()
        installOutsideClickMonitors()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLabels() }
        }
    }

    private func refreshLabels() {
        let snapshot = store.snapshot
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        setLabel(.memory, format: "R%3.0f%%", value: snapshot.memoryPercent, font: font)
        setLabel(.gpu, format: "G%3.0f%%", value: snapshot.gpuPercent ?? 0, font: font,
                 unavailable: snapshot.gpuPercent == nil)
        setLabel(.cpu, format: "C%3.0f%%", value: snapshot.cpuPercent, font: font)
    }

    private func setLabel(_ metric: Metric, format: String, value: Double, font: NSFont, unavailable: Bool = false) {
        let title = unavailable ? "G  —%" : String(format: format, value)
        items[metric]?.button?.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
    }

    private func installOutsideClickMonitors() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.closePopoversIfOutside(NSEvent.mouseLocation)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.closePopoversIfOutside(NSEvent.mouseLocation)
            }
        }
    }

    private func closePopoversIfOutside(_ point: NSPoint) {
        guard popovers.values.contains(where: \.isShown) else { return }
        let clickedStatusButton = items.values.contains { item in
            guard let button = item.button, let window = button.window else { return false }
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
        }
        if clickedStatusButton { return }

        for (metric, popover) in popovers where popover.isShown {
            let clickedInsidePopover = popover.contentViewController?.view.window?.frame.contains(point) ?? false
            if !clickedInsidePopover {
                popover.performClose(nil)
                store.hide(metric)
            }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let metric = Metric.allCases[safe: sender.tag],
              let item = items[metric], let button = item.button,
              let popover = popovers[metric] else { return }
        for (otherMetric, otherPopover) in popovers where otherMetric != metric && otherPopover.isShown {
            otherPopover.performClose(nil)
            store.hide(otherMetric)
        }
        if popover.isShown {
            popover.performClose(nil)
            store.hide(metric)
        } else {
            store.show(metric)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              let metric = popovers.first(where: { $0.value === closedPopover })?.key else { return }
        store.hide(metric)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
