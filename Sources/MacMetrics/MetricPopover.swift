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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(metric.rawValue, systemImage: metric.symbol)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Text(metric == .gpu && store.snapshot.gpuPercent == nil ? "Unavailable" : String(format: "%.0f%%", value))
                        .font(.system(size: 38, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                }
                Spacer()
            }

            if metric == .memory {
                Text("\(MetricsStore.formatBytes(store.snapshot.memoryUsed)) of \(MetricsStore.formatBytes(store.snapshot.memoryTotal))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                ProgressView(value: value, total: 100).tint(tint)
            } else {
                ProgressView(value: metric == .gpu && store.snapshot.gpuPercent == nil ? 0 : value, total: 100)
                    .tint(tint)
            }

            HStack {
                Text(metric == .cpu ? "Processes" : metric == .gpu ? "GPU activity" : "Memory use")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if metric != .gpu { Text("Top five").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.top, 1)

            if metric == .gpu {
                ContentUnavailableView("Per-process GPU data", systemImage: "gpu",
                                       description: Text("macOS does not provide a stable public API for ranking apps by GPU use. Aggregate GPU utilization appears above when the Mac exposes it."))
                    .font(.system(size: 12))
            } else {
                let processes = store.snapshot.processUsage[metric] ?? []
                if processes.isEmpty {
                    Text(metric == .cpu ? "Gathering a second sample…" : "No process data available")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(processes.enumerated()), id: \.element.id) { index, process in
                            processRow(process, rank: index + 1)
                            if index != processes.count - 1 { Divider().padding(.leading, 30) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 360, height: 420, alignment: .topLeading)
        .background(Color.clear)
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

    private var tint: Color {
        switch metric {
        case .cpu: .cyan
        case .gpu: .purple
        case .memory: .mint
        }
    }

    private func processRow(_ process: ProcessUsage, rank: Int) -> some View {
        HStack(spacing: 11) {
            Text("\(rank)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("PID \(process.pid)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if metric == .cpu {
                Text(process.detail).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            } else {
                Text(process.detail).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(String(format: "%.1f%%", process.value)).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            }
            Button {
                processToQuit = process
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Force Quit \(process.name)")
            .accessibilityLabel("Force Quit \(process.name)")
        }
        .padding(.vertical, 8)
    }
}
