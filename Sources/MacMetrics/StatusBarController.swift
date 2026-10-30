import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let preferences: AppPreferences
    private let store: MetricsStore
    private let settingsWindow: SettingsWindowController
    private let statusItem: NSStatusItem
    private let statusStack = NSStackView()
    private var metricButtons: [Metric: NSButton] = [:]
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
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        for metric in Metric.allCases {
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
        let visibleMetrics = Metric.allCases.filter(isMetricVisible)
        statusItem.isVisible = !visibleMetrics.isEmpty
        for metric in Metric.allCases {
            guard !isMetricVisible(metric), let panel = panels[metric], panel.isVisible else { continue }
            panel.orderOut(nil)
            store.hide(metric)
        }
        rebuildStatusSegments()
        updateStatusItemWidth()
        refreshLabels()
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
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let orderedMetrics: [Metric] = [.memory, .gpu, .cpu]
        for metric in orderedMetrics {
            let label = statusLabel(for: metric, snapshot: snapshot)
            metricButtons[metric]?.attributedTitle = NSAttributedString(string: label, attributes: attributes)
            metricButtons[metric]?.setAccessibilityLabel("\(metric.rawValue) \(label.dropFirst().trimmingCharacters(in: .whitespaces))")
        }

        updateStatusItemWidth()
        resizeVisiblePanels()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.target = nil
        button.action = nil
        button.isBordered = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.distribution = .fill
        statusStack.spacing = 3
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            statusStack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            statusStack.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        for metric in [Metric.memory, .gpu, .cpu] {
            let metricButton = NSButton(title: "", target: self, action: #selector(togglePopover(_:)))
            metricButton.tag = Metric.allCases.firstIndex(of: metric) ?? 0
            metricButton.isBordered = false
            metricButton.bezelStyle = .regularSquare
            metricButton.alignment = .center
            metricButton.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            metricButton.setContentHuggingPriority(.required, for: .horizontal)
            metricButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            metricButton.setAccessibilityHelp("Click to view \(metric.rawValue) details.")
            metricButtons[metric] = metricButton
        }
    }

    private func rebuildStatusSegments() {
        for view in statusStack.arrangedSubviews {
            statusStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let orderedMetrics: [Metric] = [.memory, .gpu, .cpu]
        var hasPreviousSegment = false
        for metric in orderedMetrics where isMetricVisible(metric) {
            if hasPreviousSegment {
                let separator = NSTextField(labelWithString: "·")
                separator.font = .systemFont(ofSize: 11)
                separator.textColor = .tertiaryLabelColor
                statusStack.addArrangedSubview(separator)
            }
            if let button = metricButtons[metric] {
                statusStack.addArrangedSubview(button)
                hasPreviousSegment = true
            }
        }
    }

    private func updateStatusItemWidth() {
        statusStack.layoutSubtreeIfNeeded()
        statusItem.length = max(22, statusStack.fittingSize.width + 16)
    }

    private func statusLabel(for metric: Metric, snapshot: MetricSnapshot) -> String {
        switch metric {
        case .memory: String(format: "R%3.0f%%", snapshot.memoryPercent)
        case .gpu:
            snapshot.gpuPercent.map { String(format: "G%3.0f%%", $0) } ?? "G  —%"
        case .cpu: String(format: "C%3.0f%%", snapshot.cpuPercent)
        }
    }

    private func resizeVisiblePanels() {
        for (metric, panel) in panels where panel.isVisible {
            guard let button = metricButtons[metric],
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
        let clickedStatusButton: Bool
        if let button = statusItem.button, let window = button.window {
            clickedStatusButton = window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
        } else {
            clickedStatusButton = false
        }
        if clickedStatusButton { return }

        for (metric, panel) in panels where panel.isVisible {
            if !panel.frame.contains(point) {
                panel.orderOut(nil)
                store.hide(metric)
            }
        }
    }

    @objc private func togglePopover(_ sender: NSButton) {
        guard Metric.allCases.indices.contains(sender.tag) else { return }
        let metric = Metric.allCases[sender.tag]
        guard let panel = panels[metric], let hostingController = hostingControllers[metric] else { return }
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
            position(panel, below: sender)
            panel.orderFront(nil)
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
