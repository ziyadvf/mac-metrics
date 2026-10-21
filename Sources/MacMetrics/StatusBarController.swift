import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let preferences: AppPreferences
    private let store: MetricsStore
    private let settingsWindow: SettingsWindowController
    private var items: [Metric: NSStatusItem] = [:]
    private var panels: [Metric: NSPanel] = [:]
    private var hostingControllers: [Metric: NSHostingController<MetricPopover>] = [:]
    private var refreshTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        self.store = MetricsStore(refreshInterval: preferences.refreshInterval)
        self.settingsWindow = SettingsWindowController(preferences: preferences)
        super.init()
        for metric in Metric.allCases {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.tag = Metric.allCases.firstIndex(of: metric) ?? 0
            items[metric] = item

            let hostingController = NSHostingController(rootView: MetricPopover(
                metric: metric,
                store: store,
                openSettings: { [weak self] in self?.showSettings() }
            ))
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            // Status item clicks do not always activate an accessory app; keep the
            // non-activating panel visible until the explicit outside-click monitor closes it.
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panels[metric] = panel
            hostingControllers[metric] = hostingController
        }
        bindPreferences()
        applyMetricVisibility()
        refreshLabels()
        installOutsideClickMonitors()
        scheduleLabelRefresh()
    }

    private func bindPreferences() {
        preferences.$showsCPU.sink { [weak self] _ in self?.applyMetricVisibility() }.store(in: &subscriptions)
        preferences.$showsGPU.sink { [weak self] _ in self?.applyMetricVisibility() }.store(in: &subscriptions)
        preferences.$showsRAM.sink { [weak self] _ in self?.applyMetricVisibility() }.store(in: &subscriptions)
        preferences.$refreshInterval.dropFirst().sink { [weak self] interval in
            self?.store.setRefreshInterval(interval)
            self?.scheduleLabelRefresh(interval: interval)
        }.store(in: &subscriptions)
    }

    private func applyMetricVisibility() {
        let visibility: [(Metric, Bool)] = [
            (.cpu, preferences.showsCPU),
            (.gpu, preferences.showsGPU),
            (.memory, preferences.showsRAM)
        ]
        for (metric, visible) in visibility {
            items[metric]?.isVisible = visible
            if !visible, let panel = panels[metric], panel.isVisible {
                panel.orderOut(nil)
                store.hide(metric)
            }
        }
    }

    private func scheduleLabelRefresh(interval: TimeInterval? = nil) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval ?? preferences.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLabels() }
        }
    }

    private func showSettings() {
        for (metric, panel) in panels where panel.isVisible {
            panel.orderOut(nil)
            store.hide(metric)
        }
        settingsWindow.show()
    }

    private func refreshLabels() {
        let snapshot = store.snapshot
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        setLabel(.memory, format: "R%3.0f%%", value: snapshot.memoryPercent, font: font)
        setLabel(.gpu, format: "G%3.0f%%", value: snapshot.gpuPercent ?? 0, font: font,
                 unavailable: snapshot.gpuPercent == nil)
        setLabel(.cpu, format: "C%3.0f%%", value: snapshot.cpuPercent, font: font)
        resizeVisiblePanels()
    }

    private func setLabel(_ metric: Metric, format: String, value: Double, font: NSFont, unavailable: Bool = false) {
        let title = unavailable ? "G  —%" : String(format: format, value)
        items[metric]?.button?.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
    }

    private func resizeVisiblePanels() {
        for (metric, panel) in panels where panel.isVisible {
            guard let button = items[metric]?.button,
                  let hostingController = hostingControllers[metric] else { continue }
            hostingController.view.layoutSubtreeIfNeeded()
            let measured = hostingController.sizeThatFits(in: NSSize(width: 340, height: 900))
            let size = NSSize(width: 340, height: max(210, measured.height))
            guard abs(panel.frame.height - size.height) > 1 else { continue }
            panel.setContentSize(size)
            position(panel, below: button)
        }
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
        guard panels.values.contains(where: \.isVisible) else { return }
        let clickedStatusButton = items.values.contains { item in
            guard let button = item.button, let window = button.window else { return false }
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
        }
        if clickedStatusButton { return }

        for (metric, panel) in panels where panel.isVisible {
            if !panel.frame.contains(point) {
                panel.orderOut(nil)
                store.hide(metric)
            }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let metric = Metric.allCases[safe: sender.tag],
              let item = items[metric], let button = item.button,
              let panel = panels[metric], let hostingController = hostingControllers[metric] else { return }
        for (otherMetric, otherPanel) in panels where otherMetric != metric && otherPanel.isVisible {
            otherPanel.orderOut(nil)
            store.hide(otherMetric)
        }
        if panel.isVisible {
            panel.orderOut(nil)
            store.hide(metric)
        } else {
            store.show(metric)
            hostingController.view.layoutSubtreeIfNeeded()
            let size = hostingController.sizeThatFits(in: NSSize(width: 340, height: 900))
            let height = max(210, size.height)
            panel.setContentSize(NSSize(width: 340, height: height))
            position(panel, below: button)
            panel.orderFront(nil)
        }
    }

    private func position(_ panel: NSPanel, below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - panel.frame.width / 2, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        let y = max(anchor.minY - panel.frame.height - 4, screen.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
