import Foundation
import AppKit

enum Metric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "RAM"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display.2"
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
    let icon: NSImage?
    var id: Int32 { pid }
}

enum CPUCoreType: String, Identifiable {
    case performance = "Performance"
    case efficiency = "Efficiency"
    case standard = "CPU"

    var id: String { rawValue }
}

struct CPUCoreGroup: Identifiable {
    let type: CPUCoreType
    let usage: [Double]

    var id: CPUCoreType { type }
}

struct MetricSnapshot {
    var cpuPercent: Double = 0
    var gpuPercent: Double?
    var memoryPercent: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var memoryApps: UInt64 = 0
    var memoryWired: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var swapUsed: UInt64?
    var swapTotal: UInt64?
    var cpuCoreGroups: [CPUCoreGroup] = []
    var updatedAt = Date()
    var processUsage: [Metric: [ProcessUsage]] = [:]
    var gpuProcessNote = "Per-process GPU activity is not exposed by a public macOS API."
}
