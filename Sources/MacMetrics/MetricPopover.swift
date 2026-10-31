import SwiftUI

struct MetricPopover: View {
    let metric: Metric
    @ObservedObject var store: MetricsStore
    let openSettings: () -> Void
    @State private var processToQuit: ProcessUsage?
    @State private var showTerminationFailure = false
    @State private var hoveredProcess: Int32?
    @State private var displayedProcesses: [ProcessUsage] = []
    @State private var search = ""
    @State private var isScrolling = false
    @State private var isAtTop = true
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

            if metric == .cpu, !store.snapshot.cpuCoreGroups.isEmpty {
                cpuCoreUsage
            }

            HStack(alignment: .firstTextBaseline) {
                Text(metric == .gpu ? "GPU activity" : metric == .cpu ? "CPU processes" : "Memory use")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if metric != .gpu {
                    Text("\(filteredProcesses.count) · % of \(metric == .cpu ? "CPU" : "RAM")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            if metric == .gpu {
                Text("Per-process GPU usage isn’t available in macOS.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                processSearch
                processList
            }

            Divider().padding(.top, 2)
            Button(action: openSettings) {
                HStack {
                    Label("Settings…", systemImage: "gearshape")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(settingsHovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { settingsHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: settingsHovered)
            .padding(.top, 2)
        }
        .padding(14)
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
        .confirmationDialog(
            "Force quit \(processToQuit?.name ?? "process")?",
            isPresented: Binding(get: { processToQuit != nil }, set: { if !$0 { processToQuit = nil } }),
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let processToQuit { store.forceQuit(processToQuit) }
                processToQuit = nil
                if store.terminationFailure != nil { showTerminationFailure = true }
            }
            Button("Cancel", role: .cancel) { processToQuit = nil }
        } message: {
            Text("Any unsaved work in this process will be lost.")
        }
        .alert("Couldn’t quit process", isPresented: $showTerminationFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(store.terminationFailure ?? "Try again.")
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search processes", text: $search)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search processes by name or PID")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private var processList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 0).id("process-list-top")
                    if filteredProcesses.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: search.isEmpty ? "app.dashed" : "magnifyingglass")
                                .font(.system(size: 20))
                            Text(search.isEmpty ? (metric == .cpu ? "Measuring CPU usage…" : "No process data available") : "No matching processes")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(Array(filteredProcesses.enumerated()), id: \.element.id) { index, process in
                        ProcessRow(
                            process: process,
                            rank: index + 1,
                            metric: metric,
                            loadIcon: { store.processIcon(for: process.pid) },
                            hoverChanged: { hovering in
                                if hovering { hoveredProcess = process.pid }
                                else if hoveredProcess == process.pid { hoveredProcess = nil }
                            },
                            quit: { processToQuit = process }
                        )
                    }
                }
                .padding(.vertical, 2)
                .background {
                    if #unavailable(macOS 15.0) {
                        ProcessScrollObserver(scrolling: { isScrolling = $0 }, atTop: { isAtTop = $0 })
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: 270)
            .trackProcessScrolling(changed: { isScrolling = $0 }, topChanged: { atTop in
                if isAtTop != atTop { isAtTop = atTop }
            })
            .onChange(of: search) { _, _ in
                proxy.scrollTo("process-list-top", anchor: .top)
            }
            .transaction { if isScrolling || !isAtTop { $0.animation = nil } }
        }
    }

    private func updateProcesses(_ incoming: [ProcessUsage], animate: Bool = true) {
        let preserveOrder = isScrolling || !isAtTop || hoveredProcess != nil
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
            ForEach(Array(store.snapshot.cpuCoreGroups.enumerated()), id: \.element.id) { groupIndex, group in
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
        case .performance: .blue
        case .efficiency: .teal
        case .standard: .accentColor
        }
    }

}

private extension View {
    @ViewBuilder
    func trackProcessScrolling(changed: @escaping (Bool) -> Void, topChanged: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self
                .onScrollPhaseChange { _, phase in changed(phase != .idle) }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top <= 3
                } action: { _, atTop in topChanged(atTop) }
        } else {
            self
        }
    }
}

// macOS 14 fallback: observe only this list's enclosing native scroll view.
private struct ProcessScrollObserver: NSViewRepresentable {
    let scrolling: (Bool) -> Void
    let atTop: (Bool) -> Void

    func makeNSView(context: Context) -> ProcessScrollProbe { ProcessScrollProbe() }
    func updateNSView(_ view: ProcessScrollProbe, context: Context) {
        view.scrolling = scrolling
        view.atTop = atTop
        DispatchQueue.main.async { [weak view] in view?.connect() }
    }
    static func dismantleNSView(_ view: ProcessScrollProbe, coordinator: ()) { view.disconnect() }
}

private final class ProcessScrollProbe: NSView {
    var scrolling: (Bool) -> Void = { _ in }
    var atTop: (Bool) -> Void = { _ in }
    private weak var scroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var lastTop: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() }
        else { DispatchQueue.main.async { [weak self] in self?.connect() } }
    }
    func connect() {
        guard let enclosing = enclosingScrollView, scroll !== enclosing else { return }
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
        reportTop()
    }
    func disconnect() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        scroll = nil
        lastTop = nil
    }
    private func reportTop() {
        guard let scroll else { return }
        let value = scroll.contentView.bounds.minY <= 3
        if value != lastTop { lastTop = value; atTop(value) }
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage
    let rank: Int
    let metric: Metric
    let loadIcon: () -> NSImage?
    let hoverChanged: (Bool) -> Void
    let quit: () -> Void
    @State private var icon: NSImage?
    @State private var hovered = false
    @State private var quitHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 17, alignment: .trailing)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .padding(.horizontal, 6)
        .frame(height: 50)
        .opacity(process.isRunning ? 1 : 0.45)
        .background(Color.primary.opacity(hovered ? 0.065 : (rank.isMultiple(of: 2) ? 0.018 : 0)), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovered = $0; hoverChanged($0) }
        .onAppear { icon = loadIcon() }
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
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .clipShape(shape)
        }
    }
}
