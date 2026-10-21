import SwiftUI

struct MetricPopover: View {
    let metric: Metric
    @ObservedObject var store: MetricsStore
    @State private var processToQuit: ProcessUsage?
    @State private var showTerminationFailure = false

    private var value: Double {
        switch metric {
        case .cpu: store.snapshot.cpuPercent
        case .gpu: store.snapshot.gpuPercent ?? 0
        case .memory: store.snapshot.memoryPercent
        }
    }

    private var hasValue: Bool { metric != .gpu || store.snapshot.gpuPercent != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            summaryCard

            HStack(alignment: .firstTextBaseline) {
                Text(metric == .gpu ? "GPU activity" : metric == .cpu ? "Top CPU processes" : "Memory use")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if metric != .gpu {
                    Text("TOP FIVE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)

            if metric == .gpu {
                Text("macOS doesn’t expose per-process GPU usage through a stable public API.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                processList
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuBarGlassSurface())
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

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(metric.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summaryCaption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(hasValue ? String(format: "%.0f%%", value) : "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Text(summaryDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            ProgressView(value: hasValue ? value : 0, total: 100)
                .tint(tint)
                .opacity(hasValue ? 1 : 0.35)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
        }
    }

    private var processList: some View {
        let processes = store.snapshot.processUsage[metric] ?? []
        return VStack(spacing: 0) {
            if processes.isEmpty {
                Text(metric == .cpu ? "Gathering a second sample…" : "No process data available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
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

    private var summaryCaption: String {
        switch metric {
        case .cpu: "TOTAL LOAD"
        case .gpu: "TOTAL ACTIVITY"
        case .memory: "MEMORY PRESSURE"
        }
    }

    private var summaryDetail: String {
        switch metric {
        case .cpu: "System-wide"
        case .gpu: hasValue ? "System-wide" : "Unavailable"
        case .memory:
            "\(MetricsStore.formatBytes(store.snapshot.memoryUsed)) of \(MetricsStore.formatBytes(store.snapshot.memoryTotal))"
        }
    }

    private var tint: Color {
        switch metric {
        case .cpu: .cyan
        case .gpu: .purple
        case .memory: .mint
        }
    }

    private func processRow(_ process: ProcessUsage, rank: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("PID \(process.pid)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Text(process.detail)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            if metric == .memory {
                Text(String(format: "%.1f%%", process.value))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 37, alignment: .trailing)
            }
            Button {
                processToQuit = process
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .help("Force Quit \(process.name)")
            .accessibilityLabel("Force Quit \(process.name)")
        }
        .padding(.vertical, 4)
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
