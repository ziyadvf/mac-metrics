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
    private var previousProcessorTicks: [ProcessorTicks] = []
    private var previousProcesses: [Int32: UInt64] = [:]
    private var processIcons: [Int32: NSImage?] = [:]
    private var previousProcessSample = Date()

    private struct ProcessorTicks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

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
        let current = readProcesses(includeFootprint: metric == .memory)
        let currentPIDs = Set(current.map(\.pid))
        processIcons = processIcons.filter { currentPIDs.contains($0.key) }
        let ranked: [(pid: Int32, name: String, value: Double, detail: String)]

        if metric == .cpu {
            ranked = current.compactMap { process in
                guard let priorCPUTime = previousProcesses[process.pid] else { return nil }
                let delta = process.cpuNanoseconds >= priorCPUTime
                    ? process.cpuNanoseconds - priorCPUTime : 0
                // Process CPU is shown per core: one fully occupied core is 100%.
                // A multithreaded process can therefore exceed 100%.
                let percent = Double(delta) / (elapsed * 1_000_000_000) * 100
                return (process.pid, process.name, percent, String(format: "%.1f%%", percent))
            }.sorted { $0.value > $1.value }
        } else {
            let total = max(1, snapshot.memoryTotal)
            ranked = current.compactMap { process in
                guard let footprint = process.footprint else { return nil }
                let percent = Double(footprint) / Double(total) * 100
                return (process.pid, process.name, percent, Self.formatBytes(footprint))
            }.sorted { $0.value > $1.value }
        }

        let usage = ranked.prefix(5).map { process in
            ProcessUsage(
                pid: process.pid,
                name: process.name,
                value: process.value,
                detail: process.detail,
                icon: processIcon(for: process.pid)
            )
        }

        previousProcesses = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0.cpuNanoseconds) })
        previousProcessSample = now
        snapshot.processUsage[metric] = usage
    }

    private func processIcon(for pid: Int32) -> NSImage? {
        if let cachedIcon = processIcons[pid] { return cachedIcon }
        if processIcons.keys.contains(pid) { return nil }

        let applicationIcon = NSRunningApplication(processIdentifier: pid)?.icon
        let icon = applicationIcon ?? processApplicationBundlePath(for: pid).map {
            NSWorkspace.shared.icon(forFile: $0)
        }
        processIcons[pid] = icon
        return icon
    }

    private func processApplicationBundlePath(for pid: Int32) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let executablePath = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        var directory = (executablePath as NSString).deletingLastPathComponent
        while !directory.isEmpty, directory != "/" {
            if directory.hasSuffix(".app") { return directory }
            let parent = (directory as NSString).deletingLastPathComponent
            guard parent != directory else { break }
            directory = parent
        }
        return nil
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
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS,
              let processorInfo,
              processorCount > 0 else { return snapshot.cpuPercent }

        defer {
            let byteCount = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: processorInfo), byteCount)
        }

        let values = UnsafeBufferPointer(start: processorInfo, count: Int(processorInfoCount))
        let ticksPerProcessor = MemoryLayout<processor_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        let currentTicks = (0..<Int(processorCount)).map { index in
            let offset = index * ticksPerProcessor
            return ProcessorTicks(
                user: UInt32(bitPattern: values[offset + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: values[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: values[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: values[offset + Int(CPU_STATE_NICE)])
            )
        }

        guard currentTicks.count == previousProcessorTicks.count else {
            previousProcessorTicks = currentTicks
            snapshot.cpuCoreGroups = []
            return 0
        }

        var totalBusy: UInt64 = 0
        var totalTicks: UInt64 = 0
        let perCoreUsage = zip(currentTicks, previousProcessorTicks).map { current, previous -> Double in
            let user = UInt64(current.user &- previous.user)
            let system = UInt64(current.system &- previous.system)
            let idle = UInt64(current.idle &- previous.idle)
            let nice = UInt64(current.nice &- previous.nice)
            let busy = user + system + nice
            let total = busy + idle
            totalBusy += busy
            totalTicks += total
            return total == 0 ? 0 : Double(busy) / Double(total) * 100
        }

        previousProcessorTicks = currentTicks
        snapshot.cpuCoreGroups = makeCoreGroups(from: perCoreUsage)
        return totalTicks == 0 ? snapshot.cpuPercent : Double(totalBusy) / Double(totalTicks) * 100
    }

    private func makeCoreGroups(from usage: [Double]) -> [CPUCoreGroup] {
        guard let levelCount = sysctlInteger("hw.nperflevels"), levelCount == 2,
              let performanceCount = sysctlInteger("hw.perflevel0.logicalcpu"),
              let efficiencyCount = sysctlInteger("hw.perflevel1.logicalcpu"),
              performanceCount > 0, efficiencyCount > 0,
              performanceCount + efficiencyCount == usage.count else {
            return usage.isEmpty ? [] : [CPUCoreGroup(type: .standard, usage: usage)]
        }

        // Mach enumerates Apple Silicon's efficiency CPUs first; hw.perflevel0 is
        // the highest-performance cluster, while perflevel1 is the efficiency cluster.
        let efficiency = Array(usage.prefix(efficiencyCount))
        let performance = Array(usage.suffix(performanceCount))
        return [
            CPUCoreGroup(type: .performance, usage: performance),
            CPUCoreGroup(type: .efficiency, usage: efficiency)
        ]
    }

    private func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
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
        let freeBytes = min(total, UInt64(vm.free_count) * UInt64(getpagesize()))
        return (total - freeBytes, total)
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

    private func readProcesses(includeFootprint: Bool) -> [(pid: Int32, name: String, cpuNanoseconds: UInt64, footprint: UInt64?)] {
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
            let footprint = includeFootprint ? readPhysicalFootprint(for: pid) : nil
            return (pid, name, task.pti_total_user + task.pti_total_system, footprint)
        }
    }

    private func readPhysicalFootprint(for pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
