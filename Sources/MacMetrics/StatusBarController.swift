import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
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
            popover.delegate = self
            popover.contentSize = NSSize(width: 360, height: 380)
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

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              let metric = popovers.first(where: { $0.value === closedPopover })?.key else { return }
        store.hide(metric)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
