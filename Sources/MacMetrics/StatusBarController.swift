import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let store = MetricsStore()
    private var items: [Metric: NSStatusItem] = [:]
    private var popovers: [Metric: NSPopover] = [:]
    private var refreshTimer: Timer?

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
            popover.contentSize = NSSize(width: 360, height: 420)
            popover.contentViewController = NSHostingController(rootView: MetricPopover(metric: metric, store: store))
            popovers[metric] = popover
        }
        refreshLabels()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLabels() }
        }
    }

    private func refreshLabels() {
        let snapshot = store.snapshot
        items[.cpu]?.button?.title = String(format: "CPU %.0f%%", snapshot.cpuPercent)
        items[.gpu]?.button?.title = snapshot.gpuPercent.map { String(format: "GPU %.0f%%", $0) } ?? "GPU —"
        items[.memory]?.button?.title = String(format: "RAM %.0f%%", snapshot.memoryPercent)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let metric = Metric.allCases[safe: sender.tag],
              let item = items[metric], let button = item.button,
              let popover = popovers[metric] else { return }
        if popover.isShown {
            popover.performClose(nil)
            store.hide(metric)
        } else {
            store.show(metric)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
