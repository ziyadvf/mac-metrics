import Foundation

enum Metric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "RAM"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .memory: "memorychip"
        }
    }

    var tint: String {
        switch self {
        case .cpu: "cyan"
        case .gpu: "purple"
        case .memory: "mint"
        }
    }
}

struct ProcessUsage: Identifiable {
    let pid: Int32
    let name: String
    let value: Double
    let detail: String
    var id: Int32 { pid }
}

struct MetricSnapshot {
    var cpuPercent: Double = 0
    var gpuPercent: Double?
    var memoryPercent: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var updatedAt = Date()
    var processUsage: [Metric: [ProcessUsage]] = [:]
    var gpuProcessNote = "Per-process GPU activity is not exposed by a public macOS API."
}
