import AppKit
import Darwin
import IOKit

@MainActor
final class MetricsStore: ObservableObject {
    @Published private(set) var snapshot = MetricSnapshot()
    @Published private(set) var activeMetric: Metric?
    @Published private(set) var terminationFailure: String?

    private var timer: Timer?
    private var refreshInterval: TimeInterval
    private var previousCPU = host_cpu_load_info()
    private var hasCPUBaseline = false
    private var previousProcesses: [Int32: (cpuNanoseconds: UInt64, footprint: UInt64)] = [:]
    private var previousProcessSample = Date()
    private let activeCores = max(1, ProcessInfo.processInfo.activeProcessorCount)

    init(refreshInterval: TimeInterval = 2) {
        self.refreshInterval = refreshInterval
        refresh()
        scheduleRefreshTimer()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval
        timer?.invalidate()
        scheduleRefreshTimer()
    }

    private func scheduleRefreshTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func show(_ metric: Metric) {
        activeMetric = metric
        refreshProcesses(for: metric)
    }

    func hide(_ metric: Metric) {
        if activeMetric == metric { activeMetric = nil }
    }

    func forceQuit(_ process: ProcessUsage) {
        terminationFailure = nil
        guard process.pid > 1, process.pid != getpid() else {
            terminationFailure = "This process can’t be quit from Mac Metrics."
            return
        }
        var identity = proc_bsdinfo()
        let identitySize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &identity, identitySize) == identitySize,
              identity.pbi_uid == uid_t(getuid()) else {
            terminationFailure = "macOS doesn’t allow this process to be quit from your account."
            return
        }

        let succeeded: Bool
        if let application = NSRunningApplication(processIdentifier: process.pid) {
            succeeded = application.forceTerminate()
        } else {
            succeeded = kill(process.pid, SIGKILL) == 0
        }
        if !succeeded {
            terminationFailure = "macOS couldn’t quit \(process.name). It may have already closed."
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let metric = self.activeMetric, metric != .gpu else { return }
            self.refreshProcesses(for: metric)
        }
    }

    func refreshProcesses(for metric: Metric) {
        guard metric != .gpu else { return }
        let now = Date()
        let elapsed = max(0.1, now.timeIntervalSince(previousProcessSample))
        let current = readProcesses()
        let usage: [ProcessUsage]

        if metric == .cpu {
            usage = current.compactMap { process in
                guard let prior = previousProcesses[process.pid] else { return nil }
                let delta = process.cpuNanoseconds >= prior.cpuNanoseconds
                    ? process.cpuNanoseconds - prior.cpuNanoseconds : 0
                let percent = Double(delta) / (elapsed * 1_000_000_000 * Double(activeCores)) * 100
                return ProcessUsage(pid: process.pid, name: process.name, value: percent,
                                    detail: String(format: "%.1f%%", percent))
            }.sorted { $0.value > $1.value }.prefix(5).map { $0 }
        } else {
            let total = max(1, snapshot.memoryTotal)
            usage = current.map { process in
                let percent = Double(process.footprint) / Double(total) * 100
                return ProcessUsage(pid: process.pid, name: process.name, value: percent,
                                    detail: Self.formatBytes(process.footprint))
            }.sorted { $0.value > $1.value }.prefix(5).map { $0 }
        }

        previousProcesses = Dictionary(uniqueKeysWithValues: current.map {
            ($0.pid, (cpuNanoseconds: $0.cpuNanoseconds, footprint: $0.footprint))
        })
        previousProcessSample = now
        snapshot.processUsage[metric] = usage
    }

    private func refresh() {
        snapshot.cpuPercent = readSystemCPU()
        let memory = readMemory()
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.memoryPercent = memory.total == 0 ? 0 : Double(memory.used) / Double(memory.total) * 100
        snapshot.gpuPercent = readGPUUtilization()
        snapshot.updatedAt = Date()
        if let activeMetric, activeMetric != .gpu { refreshProcesses(for: activeMetric) }
    }

    private func readSystemCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return snapshot.cpuPercent }
        defer { previousCPU = info; hasCPUBaseline = true }
        guard hasCPUBaseline else { return 0 }
        let current = info.cpu_ticks
        let previous = previousCPU.cpu_ticks
        let user = current.0 &- previous.0
        let system = current.1 &- previous.1
        let idle = current.2 &- previous.2
        let nice = current.3 &- previous.3
        let total = user &+ system &+ idle &+ nice
        return total == 0 ? 0 : Double(user &+ system &+ nice) / Double(total) * 100
    }

    private func readMemory() -> (used: UInt64, total: UInt64) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (0, total) }
        let usedPages = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        return (usedPages * UInt64(getpagesize()), total)
    }

    private func readGPUUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else {
                service = IOIteratorNext(iterator)
                continue
            }
            for key in ["Device Utilization %", "GPU Activity(%)", "GPU Busy %"] {
                if let value = stats[key] as? NSNumber { return min(100, max(0, value.doubleValue)) }
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private func readProcesses() -> [(pid: Int32, name: String, cpuNanoseconds: UInt64, footprint: UInt64)] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 16)
        let actual = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        return pids.prefix(Int(actual) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 0 else { return nil }
            var identity = proc_bsdinfo()
            let identitySize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, identitySize) == identitySize,
                  identity.pbi_uid == uid_t(getuid()) else { return nil }
            var task = proc_taskinfo()
            let bytes = withUnsafeMutablePointer(to: &task) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
            }
            guard bytes == MemoryLayout<proc_taskinfo>.size else { return nil }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { return nil }
            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (pid, name, task.pti_total_user + task.pti_total_system, task.pti_resident_size)
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
