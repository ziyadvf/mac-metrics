import SwiftUI

struct MetricPopover: View {
    let metric: Metric
    @ObservedObject var store: MetricsStore
    @State private var processToQuit: ProcessUsage?
    @State private var showTerminationFailure = false
    @State private var hoveredQuitProcess: Int32?

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

            HStack(alignment: .firstTextBaseline) {
                Text(metric == .gpu ? "GPU activity" : metric == .cpu ? "CPU processes" : "Memory use")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if metric != .gpu { Text("Top 5").font(.system(size: 11)).foregroundStyle(.secondary) }
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

    private func processRow(_ process: ProcessUsage, rank: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                Text("PID \(process.pid)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(process.detail)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
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
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(hoveredQuitProcess == process.pid ? Color.red : Color.secondary.opacity(0.55))
            .onHover { hoveredQuitProcess = $0 ? process.pid : nil }
            .help("Force Quit \(process.name)")
            .accessibilityLabel("Force Quit \(process.name)")
        }
        .padding(.vertical, 5)
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
