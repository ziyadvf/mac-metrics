import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let preferences: AppPreferences
    private let store: MetricsStore
    private let settingsWindow: SettingsWindowController
    private var statusItems: [Metric: NSStatusItem] = [:]
    private var metricButtons: [Metric: NSButton] = [:]
    private var panels: [Metric: NSPanel] = [:]
    private var hostingControllers: [Metric: NSHostingController<MetricPopover>] = [:]
    private var panelLayoutSignatures: [Metric: [Int]] = [:]
    private var observesSnapshots = false
    private var lastLabels: [Metric: String] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        self.store = MetricsStore(refreshInterval: preferences.refreshInterval)
        self.settingsWindow = SettingsWindowController(preferences: preferences)
        super.init()
        configureStatusItem()
        bindPreferences()
        applyMetricVisibility()
        installOutsideClickMonitors()
        scheduleLabelRefresh()
    }

    private func preparePanel(for metric: Metric) {
        guard panels[metric] == nil else { return }
            let hostingController = NSHostingController(rootView: MetricPopover(
                metric: metric,
                store: store,
                openSettings: { [weak self] in self?.showSettings() }
            ))
            let panel = MetricPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
            hostingController.view.layer?.cornerRadius = 16
            hostingController.view.layer?.masksToBounds = true
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

    private func bindPreferences() {
        preferences.$showsCPU.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyMetricVisibility() }.store(in: &subscriptions)
        preferences.$showsGPU.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyMetricVisibility() }.store(in: &subscriptions)
        preferences.$showsRAM.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyMetricVisibility() }.store(in: &subscriptions)
        preferences.$refreshInterval.dropFirst().sink { [weak self] interval in
            self?.store.setRefreshInterval(interval)
            self?.scheduleLabelRefresh(interval: interval)
        }.store(in: &subscriptions)
    }

    private func applyMetricVisibility() {
        for metric in Metric.allCases { statusItems[metric]?.isVisible = isMetricVisible(metric) }
        for metric in Metric.allCases {
            guard !isMetricVisible(metric), let panel = panels[metric], panel.isVisible else { continue }
            panel.orderOut(nil)
            store.hide(metric)
            metricButtons[metric]?.state = .off
        }
        refreshLabels()
    }

    private func isMetricVisible(_ metric: Metric) -> Bool {
        switch metric {
        case .cpu: preferences.showsCPU
        case .gpu: preferences.showsGPU
        case .memory: preferences.showsRAM
        }
    }

    private func scheduleLabelRefresh(interval: TimeInterval? = nil) {
        guard !observesSnapshots else { return }
        observesSnapshots = true
        // The sampling timer is the sole clock. Deliver after its snapshot commit.
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshLabels()
        }.store(in: &subscriptions)
    }

    private func showSettings() {
        for (metric, panel) in panels where panel.isVisible {
            panel.orderOut(nil)
            store.hide(metric)
            metricButtons[metric]?.state = .off
        }
        settingsWindow.show()
    }

    private func refreshLabels() {
        let snapshot = store.snapshot
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let orderedMetrics: [Metric] = [.memory, .gpu, .cpu]
        for metric in orderedMetrics {
            let label = statusLabel(for: metric, snapshot: snapshot)
            guard lastLabels[metric] != label else { continue }
            lastLabels[metric] = label
            metricButtons[metric]?.attributedTitle = NSAttributedString(string: label, attributes: attributes)
            let accessibleValue = metric == .gpu && snapshot.gpuPercent == nil
                ? "unavailable" : String(label.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            metricButtons[metric]?.setAccessibilityLabel("\(metric.rawValue) usage: \(accessibleValue)")
        }

        resizeVisiblePanels()
    }

    private func configureStatusItem() {
        // Each metric is an independent system status item, with its own native
        // button and highlight. Creating them consecutively keeps the initial
        // layout adjacent; macOS owns their subsequent positioning.
        for metric in [Metric.memory, .gpu, .cpu] {
            let item = NSStatusBar.system.statusItem(withLength: 45)
            item.autosaveName = "MacMetrics.\(metric.rawValue)"
            guard let button = item.button else { continue }
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.tag = Metric.allCases.firstIndex(of: metric) ?? 0
            button.focusRingType = .none
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.toolTip = "\(metric.rawValue) usage"
            button.setAccessibilityHelp("Click to view \(metric.rawValue) details.")
            statusItems[metric] = item
            metricButtons[metric] = button
        }
    }

    private func statusLabel(for metric: Metric, snapshot: MetricSnapshot) -> String {
        let prefix: String
        let value: Double?
        switch metric {
        case .cpu: prefix = "C"; value = snapshot.cpuPercent
        case .gpu: prefix = "G"; value = snapshot.gpuPercent
        case .memory: prefix = "R"; value = snapshot.memoryPercent
        }
        guard let value else { return "\(prefix)\u{2009}–%" }
        let digits = String(format: "%.0f", min(100, max(0, value)))
        return prefix + "\u{2009}" + digits + "%"
    }

    private func resizeVisiblePanels() {
        for (metric, panel) in panels where panel.isVisible {
            guard let button = metricButtons[metric],
                  let hostingController = hostingControllers[metric] else { continue }
            let signature = layoutSignature(for: metric)
            guard panelLayoutSignatures[metric] != signature else { continue }
            panelLayoutSignatures[metric] = signature
            hostingController.view.layoutSubtreeIfNeeded()
            let measured = hostingController.sizeThatFits(in: NSSize(width: 340, height: 900))
            let size = NSSize(width: 340, height: max(210, measured.height))
            guard abs(panel.frame.height - size.height) > 1 else { continue }
            panel.setContentSize(size)
            position(panel, below: button)
        }
    }

    private func layoutSignature(for metric: Metric) -> [Int] {
        metric == .cpu ? store.snapshot.cpuCoreGroups.map { $0.usage.count } : []
    }

    private func installOutsideClickMonitors() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53,
               let metric = self.panels.first(where: { $0.value.isVisible && $0.value.isKeyWindow })?.key {
                if !(self.store.searchQueries[metric] ?? "").isEmpty {
                    self.store.searchQueries[metric] = ""
                } else {
                    self.panels[metric]?.orderOut(nil)
                    self.store.hide(metric)
                    self.metricButtons[metric]?.state = .off
                }
                return nil
            }
            if event.type == .rightMouseDown {
                let point = NSEvent.mouseLocation
                for item in self.statusItems.values {
                    guard let button = item.button, let window = button.window,
                          window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) else { continue }
                    let menu = NSMenu()
                    let quit = NSMenuItem(title: "Quit Mac Metrics", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
                    quit.target = NSApp
                    menu.addItem(quit)
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
                    return nil
                }
            }
            if event.type != .keyDown { self.closePopoversIfOutside(NSEvent.mouseLocation) }
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
        let clickedStatusButton = statusItems.values.contains { item in
            guard item.isVisible, let button = item.button, let window = button.window else { return false }
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
        }
        if clickedStatusButton { return }

        for (metric, panel) in panels where panel.isVisible {
            if !panel.frame.contains(point) {
                panel.orderOut(nil)
                store.hide(metric)
                metricButtons[metric]?.state = .off
            }
        }
    }

    @objc private func togglePopover(_ sender: NSButton) {
        guard Metric.allCases.indices.contains(sender.tag) else { return }
        let metric = Metric.allCases[sender.tag]
        preparePanel(for: metric)
        guard let panel = panels[metric], let hostingController = hostingControllers[metric] else { return }
        for (otherMetric, otherPanel) in panels where otherMetric != metric && otherPanel.isVisible {
            otherPanel.orderOut(nil)
            store.hide(otherMetric)
            metricButtons[otherMetric]?.state = .off
        }
        if panel.isVisible {
            panel.orderOut(nil)
            store.hide(metric)
            metricButtons[metric]?.state = .off
        } else {
            store.show(metric)
            sender.state = .on
            hostingController.view.layoutSubtreeIfNeeded()
            let size = hostingController.sizeThatFits(in: NSSize(width: 340, height: 900))
            let height = max(210, size.height)
            panel.setContentSize(NSSize(width: 340, height: height))
            panelLayoutSignatures[metric] = layoutSignature(for: metric)
            position(panel, below: sender)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func position(_ panel: NSPanel, below button: NSView) {
        guard let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - panel.frame.width / 2, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        let y = max(anchor.minY - panel.frame.height - 4, screen.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class MetricPanel: NSPanel {
    // Borderless panels cannot receive keyboard focus unless explicitly allowed.
    override var canBecomeKey: Bool { true }
}
