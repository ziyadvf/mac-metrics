import SwiftUI

struct MetricPopover: View {
    let metric: Metric
    @ObservedObject var store: MetricsStore
    let openSettings: () -> Void
    @State private var hoveredProcess: Int32?
    @State private var selectedProcess: Int32?
    @State private var displayedProcesses: [ProcessUsage] = []
    private var search: String {
        get { store.searchQueries[metric] ?? "" }
        nonmutating set { store.searchQueries[metric] = newValue }
    }
    @State private var isScrolling = false
    @State private var isAtTop = true
    @State private var isAtBottom = true
    @State private var settingsHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var value: Double {
        switch metric {
        case .cpu: store.snapshot.cpuPercent
        case .gpu: store.snapshot.gpuPercent ?? 0
        case .memory: store.snapshot.memoryPercent
        }
    }

    private var hasValue: Bool { metric != .gpu || store.snapshot.gpuPercent != nil }

    var body: some View {
        Group {
            if store.activeMetric == metric { panelContent }
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
            metricSummary

            if metric == .memory {
                memoryBreakdown
                HStack {
                    Text("Swap")
                    Spacer()
                    if let used = store.snapshot.swapUsed, let total = store.snapshot.swapTotal {
                        Text("\(MetricsStore.formatBytes(used)) / \(MetricsStore.formatBytes(total))")
                            .monospacedDigit()
                    } else {
                        Text("Unavailable")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
            }

            if metric == .cpu {
                cpuCoreUsage
                    .modifier(LoadingShimmer(loading: store.snapshot.cpuCoreGroups.isEmpty))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.snapshot.cpuCoreGroups.isEmpty)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(metric == .gpu ? "GPU time · % of interval" : metric == .cpu ? "CPU processes" : "Memory use")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if metric != .gpu {
                    Text("\(filteredProcesses.count) · % of \(metric == .cpu ? "CPU" : "RAM")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            processSearch
            processList

            }
            .padding(.horizontal, 16)
            .padding(.top, 15)

            VStack(spacing: 0) {
                Divider().padding(.horizontal, 16)
                Button(action: openSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .background(Color.primary.opacity(settingsHovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { settingsHovered = $0 }
                .padding(8)
            }
        }
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuBarGlassSurface())
        .transaction { if reduceMotion { $0.animation = nil } }
        .onAppear { updateProcesses(store.snapshot.processUsage[metric] ?? [], animate: false) }
        .onChange(of: store.snapshot.processUsage[metric] ?? []) { _, incoming in
            updateProcesses(incoming)
        }
        .onChange(of: isScrolling) { _, scrolling in
            if !scrolling && isAtTop { updateProcesses(store.snapshot.processUsage[metric] ?? []) }
        }
        .onChange(of: isAtTop) { _, atTop in
            if atTop && !isScrolling { updateProcesses(store.snapshot.processUsage[metric] ?? []) }
        }
    }

    private func confirmQuit(_ process: ProcessUsage) {
        let alert = NSAlert()
        alert.messageText = "Force quit \(process.name)?"
        alert.informativeText = "Any unsaved work in this process will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Force Quit")
        alert.buttons.last?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        store.forceQuit(process)
        if let failure = store.terminationFailure {
            let error = NSAlert()
            error.messageText = "Couldn’t quit process"
            error.informativeText = failure
            error.runModal()
        }
    }

    private var metricSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(hasValue ? String(format: "%.0f%%", value) : "—")
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: Int(value.rounded()))
                Spacer(minLength: 0)
                if !summaryDetail.isEmpty {
                    Text(summaryDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
    }

    private var filteredProcesses: [ProcessUsage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return displayedProcesses }
        return displayedProcesses.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
    }

    private var processSearch: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            ProcessSearchField(text: Binding(get: { search }, set: { search = $0 }))
                .accessibilityLabel("Search processes by name or PID")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Clear search")
            }
        }
        .font(.system(size: 12))
        .frame(height: 18)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    private var processList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 0).id("process-list-top")
                    if filteredProcesses.isEmpty {
                        if metric == .gpu && store.gpuAttributionAvailable == false {
                            Text("GPU process counters are unavailable on this Mac.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if search.isEmpty {
                            ForEach(0..<5) { index in
                                ProcessRow(
                                    process: ProcessUsage(pid: Int32(-index - 1), name: "Application name", value: 0, detail: metric == .cpu ? "0.0%" : "100.0 MB", icon: nil),
                                    rank: index + 1, metric: metric, isScrolling: true,
                                    selected: false, select: {}, loadIcon: { nil }, hoverChanged: { _ in }, quit: {}
                                )
                                .modifier(LoadingShimmer(loading: true))
                                .transition(.opacity)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        } else {
                            Text("No matching processes")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    ForEach(Array(filteredProcesses.enumerated()), id: \.element.id) { index, process in
                        ProcessRow(
                            process: process,
                            rank: index + 1,
                            metric: metric,
                            isScrolling: isScrolling,
                            selected: selectedProcess == process.pid,
                            cpuDetail: metric == .cpu && selectedProcess == process.pid ? store.selectedCPUDetail : nil,
                            select: {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.26)) {
                                    selectedProcess = selectedProcess == process.pid ? nil : process.pid
                                }
                            },
                            loadIcon: { store.processIcon(for: process.pid) },
                            hoverChanged: { hovering in
                                if hovering { hoveredProcess = process.pid }
                                else if hoveredProcess == process.pid { hoveredProcess = nil }
                            },
                            quit: { confirmQuit(process) }
                        )
                        .id(process.pid)
                    }
                }
                .frame(width: 308)
                .padding(.horizontal, 16)
                .scrollTargetLayout()
                .padding(.top, 2)
                .padding(.bottom, 6)
                .background {
                    OverlayScrollerConfiguration()
                    if #unavailable(macOS 15.0) {
                        ProcessScrollObserver(scrolling: { isScrolling = $0 }, atTop: { isAtTop = $0 }, atBottom: { isAtBottom = $0 })
                    }
                }
            }
            .scrollIndicators(.automatic)
            .scrollTargetBehavior(.viewAligned)
            .frame(height: 266)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [isAtTop ? .white : .clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                    Rectangle().fill(.white)
                    LinearGradient(colors: [.white, isAtBottom ? .white : .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                }
            }
            .trackProcessScrolling(changed: { isScrolling = $0 }, edgesChanged: { edges in
                if isAtTop != edges.atTop { isAtTop = edges.atTop }
                if isAtBottom != edges.atBottom { isAtBottom = edges.atBottom }
            })
            .onChange(of: search) { _, _ in
                proxy.scrollTo("process-list-top", anchor: .top)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: displayedProcesses.isEmpty)
            .onChange(of: selectedProcess) { _, pid in
                if metric == .cpu { store.selectedCPUPID = pid }
                guard let pid else { return }
                updateProcesses(store.snapshot.processUsage[metric] ?? [])
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(pid, anchor: .center)
                }
            }
            .onChange(of: isScrolling) { _, scrolling in
                guard !scrolling, let pid = selectedProcess else { return }
                updateProcesses(store.snapshot.processUsage[metric] ?? [])
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(pid, anchor: .center)
                }
            }
            .onChange(of: displayedProcesses) { _, _ in
                guard let pid = selectedProcess, !isScrolling,
                      filteredProcesses.contains(where: { $0.pid == pid }) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(pid, anchor: .center)
                }
            }
            .transaction { if selectedProcess == nil && (isScrolling || !isAtTop) { $0.animation = nil } }
        }
        .padding(.horizontal, -16)
    }

    private func updateProcesses(_ incoming: [ProcessUsage], animate: Bool = true) {
        let preserveOrder = selectedProcess == nil && (isScrolling || !isAtTop || hoveredProcess != nil)
        let next = ProcessListOrder.reconcile(current: displayedProcesses, incoming: incoming, preserveOrder: preserveOrder)
        guard next != displayedProcesses else { return }
        if animate && !preserveOrder && !reduceMotion && !displayedProcesses.isEmpty {
            withAnimation(.easeInOut(duration: 0.18)) { displayedProcesses = next }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { displayedProcesses = next }
        }
    }

    private var summaryDetail: String {
        switch metric {
        case .cpu: ""
        case .gpu: hasValue ? "" : "Unavailable"
        case .memory:
            "\(MetricsStore.formatBytes(store.snapshot.memoryUsed)) of \(MetricsStore.formatBytes(store.snapshot.memoryTotal))"
        }
    }

    private var cpuCoreUsage: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((store.snapshot.cpuCoreGroups.isEmpty ? store.coreLayout : store.snapshot.cpuCoreGroups).enumerated()), id: \.element.id) { groupIndex, group in
                if groupIndex > 0 { Divider() }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(group.type.rawValue) cores")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(group.usage.count)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    let rows = max(1, (group.usage.count + 5) / 6)
                    let columns = max(1, (group.usage.count + rows - 1) / rows)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                        ForEach(Array(group.usage.enumerated()), id: \.offset) { index, percent in
                            VStack(spacing: 5) {
                                HStack(spacing: 2) {
                                    Text("\(corePrefix(for: group.type))\(index + 1)")
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                    Text(String(format: "%.0f%%", percent))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.10))
                                        Capsule()
                                            .fill(coreTint(for: group.type))
                                            .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                                    }
                                }
                                .frame(height: 6)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: percent)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(group.type.rawValue) core \(index + 1), \(Int(percent.rounded())) percent")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var memoryBreakdown: some View {
        let snapshot = store.snapshot
        let segments: [(String, UInt64, Color)] = [
            ("Apps", snapshot.memoryApps, .teal),
            ("Wired", snapshot.memoryWired, .blue),
            ("Compressed", snapshot.memoryCompressed, .purple)
        ]
        return VStack(spacing: 9) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    HStack(spacing: 0) {
                        ForEach(segments.indices, id: \.self) { index in
                            Rectangle()
                                .fill(segments[index].2)
                                .frame(width: geometry.size.width * Double(segments[index].1) / Double(max(1, snapshot.memoryTotal)))
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 6)
            HStack(alignment: .top, spacing: 8) {
                ForEach(segments.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle().fill(segments[index].2).frame(width: 5, height: 5)
                            Text(segments[index].0).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10))
                        Text(MetricsStore.formatBytes(segments[index].1))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: snapshot.memoryUsed)
        .accessibilityLabel("Apps \(MetricsStore.formatBytes(snapshot.memoryApps)), wired \(MetricsStore.formatBytes(snapshot.memoryWired)), compressed \(MetricsStore.formatBytes(snapshot.memoryCompressed))")
    }

    private func corePrefix(for type: CPUCoreType) -> String {
        switch type {
        case .performance: "P"
        case .efficiency: "E"
        case .standard: "C"
        }
    }

    private func coreTint(for type: CPUCoreType) -> Color {
        switch type {
        case .performance: .red
        case .efficiency: .blue
        case .standard: .accentColor
        }
    }

}

private struct ProcessScrollEdges: Equatable {
    let atTop: Bool
    let atBottom: Bool
}

private extension View {
    @ViewBuilder
    func trackProcessScrolling(changed: @escaping (Bool) -> Void, edgesChanged: @escaping (ProcessScrollEdges) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self
                .onScrollPhaseChange { _, phase in changed(phase != .idle) }
                .onScrollGeometryChange(for: ProcessScrollEdges.self) { geometry in
                    ProcessScrollEdges(
                        atTop: geometry.contentOffset.y + geometry.contentInsets.top <= 3,
                        atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 3
                    )
                } action: { _, edges in edgesChanged(edges) }
        } else {
            self
        }
    }
}

// Keep system scrollbar preferences from reserving space on just one side.
private struct OverlayScrollerConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        DispatchQueue.main.async { [weak view] in view?.configure() }
    }
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        func configure() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            scroll.autohidesScrollers = true
        }
    }
}

// macOS 14 fallback: observe only this list's enclosing native scroll view.
private struct ProcessScrollObserver: NSViewRepresentable {
    let scrolling: (Bool) -> Void
    let atTop: (Bool) -> Void
    let atBottom: (Bool) -> Void

    func makeNSView(context: Context) -> ProcessScrollProbe { ProcessScrollProbe() }
    func updateNSView(_ view: ProcessScrollProbe, context: Context) {
        view.scrolling = scrolling
        view.atTop = atTop
        view.atBottom = atBottom
        DispatchQueue.main.async { [weak view] in view?.connect() }
    }
    static func dismantleNSView(_ view: ProcessScrollProbe, coordinator: ()) { view.disconnect() }
}

private final class ProcessScrollProbe: NSView {
    var scrolling: (Bool) -> Void = { _ in }
    var atTop: (Bool) -> Void = { _ in }
    var atBottom: (Bool) -> Void = { _ in }
    private weak var scroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var lastTop: Bool?
    private var lastBottom: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() }
        else { DispatchQueue.main.async { [weak self] in self?.connect() } }
    }
    func connect() {
        guard let enclosing = enclosingScrollView else { return }
        if scroll === enclosing { reportTop(); return }
        disconnect()
        scroll = enclosing
        let clip = enclosing.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportTop() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: enclosing, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolling(true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: enclosing, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolling(false) }
        })
        if let document = enclosing.documentView {
            document.postsFrameChangedNotifications = true
            document.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportTop() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportTop() }
            })
        }
        reportTop()
    }
    func disconnect() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        scroll = nil
        lastTop = nil
        lastBottom = nil
    }
    private func reportTop() {
        guard let scroll else { return }
        let value = scroll.contentView.bounds.minY <= 3
        if value != lastTop { lastTop = value; atTop(value) }
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        let bottom = scroll.contentView.bounds.maxY >= documentHeight - 3
        if bottom != lastBottom { lastBottom = bottom; atBottom(bottom) }
    }
}

// SwiftUI's plain field can still inherit an AppKit focus ring. Suppress only
// the decoration; keep the native field, keyboard focus, and accessibility.
private struct ProcessSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Search processes"
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private final class SearchTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        super.mouseDown(with: event)
        (currentEditor() as? NSTextView)?.insertionPointColor = .labelColor
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage
    let rank: Int
    let metric: Metric
    let isScrolling: Bool
    let selected: Bool
    var cpuDetail: (performance: Double, efficiency: Double)? = nil
    let select: () -> Void
    let loadIcon: () -> NSImage?
    let hoverChanged: (Bool) -> Void
    let quit: () -> Void
    @State private var icon: NSImage?
    @State private var hovered = false
    @State private var quitHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var performanceColor: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.48, blue: 0.51) : Color(red: 0.72, green: 0.16, blue: 0.22)
    }
    private var efficiencyColor: Color {
        colorScheme == .dark ? Color(red: 0.35, green: 0.79, blue: 1) : Color(red: 0.02, green: 0.38, blue: 0.58)
    }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.07))
                        .overlay {
                            Image(systemName: "app.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(process.name)
                Text("PID \(process.pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(process.isRunning ? process.detail : "Ended")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if metric == .memory && process.isRunning {
                    Text(String(format: "%.1f%%", process.value))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: 68, alignment: .trailing)
            Button(action: quit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(quitHovered ? Color.red : Color.secondary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!process.isRunning)
            .opacity(hovered && process.isRunning ? 1 : 0)
            .onHover { quitHovered = $0 }
            .help("Force Quit \(process.name)")
            .accessibilityLabel("Force Quit \(process.name)")
        }
        .frame(height: 50)
        if selected && metric == .cpu {
            VStack(spacing: 7) {
                HStack {
                    Text(cpuDetail.map { String(format: "Performance %.1f%%", $0.performance) } ?? "Performance —")
                        .foregroundStyle(performanceColor)
                    Spacer()
                    Text(cpuDetail.map { String(format: "Efficiency %.1f%%", $0.efficiency) } ?? "Efficiency —")
                        .foregroundStyle(efficiencyColor)
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                GeometryReader { geometry in
                    let total = (cpuDetail?.performance ?? 0) + (cpuDetail?.efficiency ?? 0)
                    HStack(spacing: 0) {
                        Rectangle().fill(performanceColor)
                            .frame(width: total > 0 ? geometry.size.width * (cpuDetail?.performance ?? 0) / total : 0)
                        Rectangle().fill(efficiencyColor)
                            .frame(width: total > 0 ? geometry.size.width * (cpuDetail?.efficiency ?? 0) / total : 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                .modifier(LoadingShimmer(loading: cpuDetail == nil))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
        }
        .padding(.horizontal, 6)
        .frame(height: selected && metric == .cpu ? 88 : 50, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: selected)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: cpuDetail?.performance)
        .opacity(process.isRunning ? 1 : 0.45)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovered ? 0.065 : (rank.isMultiple(of: 2) ? 0.018 : 0)), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0; hoverChanged($0) }
        .task(id: isScrolling) {
            guard !isScrolling, icon == nil else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            icon = loadIcon()
        }
        .onDisappear { hoverChanged(false) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: quitHovered)
    }
}

private struct MenuBarGlassSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
        }
    }
}

private struct LoadingShimmer: ViewModifier {
    let loading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if loading {
            content
                .redacted(reason: .placeholder)
                .phaseAnimator(reduceMotion ? [false] : [false, true]) { view, phase in
                    view.opacity(0.55)
                        .overlay {
                            if !reduceMotion {
                                GeometryReader { geometry in
                                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: geometry.size.width * 0.6)
                                        .offset(x: phase ? geometry.size.width : -geometry.size.width * 0.6)
                                }
                                .mask(content.redacted(reason: .placeholder))
                                .allowsHitTesting(false)
                            }
                        }
                } animation: { phase in phase ? .easeInOut(duration: 1.8) : .linear(duration: 0) }
                .accessibilityLabel("Loading")
        } else {
            content.transition(.opacity)
        }
    }
}
