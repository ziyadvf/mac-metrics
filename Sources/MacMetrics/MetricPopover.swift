import SwiftUI

struct MetricPopover: View {
    let metric: Metric
    @ObservedObject var store: MetricsStore

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
                    Text(metric.rawValue).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Text(metric == .gpu && store.snapshot.gpuPercent == nil ? "Unavailable" : String(format: "%.0f%%", value))
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                }
                Spacer()
                Image(systemName: metric.symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if metric == .memory {
                Text("\(MetricsStore.formatBytes(store.snapshot.memoryUsed)) of \(MetricsStore.formatBytes(store.snapshot.memoryTotal))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            } else {
                ProgressView(value: metric == .gpu && store.snapshot.gpuPercent == nil ? 0 : value, total: 100)
                    .tint(tint)
            }

            HStack {
                Text(metric == .cpu ? "TOP PROCESSES" : metric == .gpu ? "GPU ACTIVITY" : "MEMORY FOOTPRINT")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.1).foregroundStyle(.secondary)
                Spacer()
                if metric != .gpu { Text("TOP 5").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.top, 2)

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
                            if index != processes.count - 1 { Divider().padding(.leading, 38) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("Updated just now · sampled every 2 seconds")
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 360, height: 420, alignment: .topLeading)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
            }
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
            Text(String(format: "%02d", rank)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 18)
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
        }
        .padding(.vertical, 9)
    }
}
