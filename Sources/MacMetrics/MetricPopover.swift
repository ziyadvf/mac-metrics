import SwiftUI

struct MetricPopover: View {
    let metric: Metric
    @ObservedObject var store: MetricsStore
    let openSettings: () -> Void
    @State private var processToQuit: ProcessUsage?
    @State private var showTerminationFailure = false
    @State private var hoveredProcess: Int32?

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

            if metric == .cpu, !store.snapshot.cpuCoreGroups.isEmpty {
                cpuCoreUsage
            }

            HStack(alignment: .firstTextBaseline) {
                Text(metric == .gpu ? "GPU activity" : metric == .cpu ? "CPU processes" : "Memory use")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if metric != .gpu {
                    Text(metric == .cpu ? "Top 5 · per core" : "Top 5 · % of RAM")
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
                processList
            }

            Divider().padding(.top, 2)
            Button(action: openSettings) {
                Label("Settings…", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuBarGlassSurface())
        .transaction { $0.animation = nil }
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

    private var processList: some View {
        let processes = store.snapshot.processUsage[metric] ?? []
        return VStack(spacing: 0) {
            if processes.isEmpty {
                HStack(spacing: 8) {
                    if metric == .cpu { ProgressView().controlSize(.small) }
                    Text(metric == .cpu ? "Measuring CPU usage…" : "No process data available")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ForEach(Array(processes.enumerated()), id: \.element.id) { index, process in
                    processRow(process, rank: index + 1)
                    if index != processes.count - 1 {
                        Divider().padding(.leading, 22)
                    }
                }
            }
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 27), spacing: 5)], alignment: .leading, spacing: 5) {
                        ForEach(Array(group.usage.enumerated()), id: \.offset) { index, percent in
                            VStack(spacing: 3) {
                                Text(String(format: "%.0f%%", percent))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.10))
                                        Capsule()
                                            .fill(coreTint(for: group.type))
                                            .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                                    }
                                }
                                .frame(height: 4)
                                Text("\(index + 1)")
                                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func coreTint(for type: CPUCoreType) -> Color {
        switch type {
        case .performance: .blue
        case .efficiency: .teal
        case .standard: .accentColor
        }
    }

    private func processRow(_ process: ProcessUsage, rank: Int) -> some View {
        HStack(spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .leading)
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PID \(process.pid)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Text(process.detail)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: metric == .memory ? 64 : 42, alignment: .trailing)
            if metric == .memory {
                Text(String(format: "%.1f%%", process.value))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 37, alignment: .trailing)
            }
            Button {
                processToQuit = process
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(hoveredProcess == process.pid ? Color.red : Color.secondary.opacity(0.55))
            .opacity(hoveredProcess == process.pid ? 1 : 0)
            .help("Force Quit \(process.name)")
            .accessibilityLabel("Force Quit \(process.name)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(hoveredProcess == process.pid ? 0.045 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hoveredProcess = $0 ? process.pid : nil }
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
