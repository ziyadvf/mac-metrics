import AppKit
import Darwin
import IOKit

@MainActor
final class MetricsStore: ObservableObject {
    @Published var searchQueries: [Metric: String] = [:]
    private var snapshotStorage = MetricSnapshot()
    private var batchingSnapshot = false
    private(set) var snapshot: MetricSnapshot {
        get { snapshotStorage }
        set {
            if !batchingSnapshot { objectWillChange.send() }
            snapshotStorage = newValue
        }
    }
    @Published private(set) var activeMetric: Metric?
    @Published private(set) var terminationFailure: String?

    private let cpuNanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(max(1, timebase.denom))
    }()
    private let logicalCoreCount = max(1, ProcessInfo.processInfo.processorCount)
    private var processSamplingTask: Task<Void, Never>?
    private var timer: Timer?
    private var idleCleanupTask: Task<Void, Never>?
    private var refreshInterval: TimeInterval
    private var previousProcessorTicks: [ProcessorTicks] = []
    private var previousProcesses: [Int32: UInt64] = [:]
    private var processIcons: [Int32: NSImage?] = [:]
    private var previousProcessSample = ProcessInfo.processInfo.systemUptime
    private lazy var coreTypes = readCoreTypes()

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
        timer?.tolerance = min(0.5, refreshInterval * 0.2)
    }

    func show(_ metric: Metric) {
        idleCleanupTask?.cancel()
        idleCleanupTask = nil
        activeMetric = metric
        refreshProcesses(for: metric)
    }

    func hide(_ metric: Metric) {
        guard activeMetric == metric else { return }
        activeMetric = nil
        idleCleanupTask?.cancel()
        idleCleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.activeMetric == nil else { return }
            self.previousProcesses.removeAll()
            self.processIcons.removeAll()
            self.snapshot.processUsage.removeAll()
        }
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
        guard activeMetric == metric, metric != .gpu, processSamplingTask == nil else { return }
        processSamplingTask = Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                let values = Self.readProcesses(includeFootprint: metric == .memory)
                let timestamp = (start + ProcessInfo.processInfo.systemUptime) / 2
                return (timestamp, values)
            }.value
            guard let self else { return }
            self.processSamplingTask = nil
            guard self.activeMetric == metric else {
                if let active = self.activeMetric { self.refreshProcesses(for: active) }
                return
            }
            self.applyProcessSample(sample.1, sampledAt: sample.0, for: metric)
        }
    }

    private func applyProcessSample(
        _ current: [(pid: Int32, name: String, cpuAbsoluteTime: UInt64, footprint: UInt64?)],
        sampledAt now: TimeInterval,
        for metric: Metric
    ) {
        let elapsed = max(0.001, now - previousProcessSample)
        let currentPIDs = Set(current.map(\.pid))
        processIcons = processIcons.filter { currentPIDs.contains($0.key) }
        let ranked: [(pid: Int32, name: String, value: Double, detail: String)]

        if metric == .cpu {
            ranked = current.compactMap { process in
                guard let priorCPUTime = previousProcesses[process.pid] else { return nil }
                let delta = process.cpuAbsoluteTime >= priorCPUTime
                    ? process.cpuAbsoluteTime - priorCPUTime : 0
                // Normalize process CPU time to the whole machine, matching the
                // system CPU scale. One occupied core on an 8-core Mac is 12.5%.
                let percent = Double(delta) * cpuNanosecondsPerTick / (elapsed * 1_000_000_000 * Double(logicalCoreCount)) * 100
                return (process.pid, process.name, percent, String(format: "%.1f%%", percent))
            }.sorted { $0.value == $1.value ? $0.pid < $1.pid : $0.value > $1.value }
        } else {
            let total = max(1, snapshot.memoryTotal)
            ranked = current.compactMap { process in
                guard let footprint = process.footprint else { return nil }
                let percent = Double(footprint) / Double(total) * 100
                return (process.pid, process.name, percent, Self.formatBytes(footprint))
            }.sorted { $0.value == $1.value ? $0.pid < $1.pid : $0.value > $1.value }
        }

        let usage = ranked.map { process in
            ProcessUsage(
                pid: process.pid,
                name: process.name,
                value: process.value,
                detail: process.detail,
                icon: nil
            )
        }

        previousProcesses = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0.cpuAbsoluteTime) })
        previousProcessSample = now
        snapshot.processUsage[metric] = usage
    }

    func processIcon(for pid: Int32) -> NSImage? {
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
        objectWillChange.send()
        batchingSnapshot = true
        defer { batchingSnapshot = false }
        snapshot.cpuPercent = readSystemCPU()
        let memory = readMemory()
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.memoryPercent = memory.total == 0 ? 0 : Double(memory.used) / Double(memory.total) * 100
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
            snapshot.swapTotal = swap.xsu_total
        } else {
            snapshot.swapUsed = nil
            snapshot.swapTotal = nil
        }
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
        if activeMetric == .cpu { snapshot.cpuCoreGroups = makeCoreGroups(from: perCoreUsage) }
        return totalTicks == 0 ? snapshot.cpuPercent : Double(totalBusy) / Double(totalTicks) * 100
    }

    private func makeCoreGroups(from usage: [Double]) -> [CPUCoreGroup] {
        guard usage.indices.allSatisfy({ coreTypes[$0] != nil }) else {
            return usage.isEmpty ? [] : [CPUCoreGroup(type: .standard, usage: usage)]
        }
        return [CPUCoreType.performance, .efficiency, .standard].compactMap { type in
            let values = usage.indices.filter { coreTypes[$0] == type }.map { usage[$0] }
            return values.isEmpty ? nil : CPUCoreGroup(type: type, usage: values)
        }
    }

    private func readCoreTypes() -> [Int: CPUCoreType] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [Int: CPUCoreType] = [:]
        var cpu = IOIteratorNext(iterator)
        while cpu != 0 {
            let entry = cpu
            defer { IOObjectRelease(entry) }
            if let number = IORegistryEntryCreateCFProperty(cpu, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
               let cluster = IORegistryEntryCreateCFProperty(cpu, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                let name = String(decoding: cluster.prefix { $0 != 0 }, as: UTF8.self)
                if name == "P" { result[number.intValue] = .performance }
                if name == "E" { result[number.intValue] = .efficiency }
            }
            cpu = IOIteratorNext(iterator)
        }
        return result
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
        guard result == KERN_SUCCESS else { return (snapshot.memoryUsed, total) }
        // Anonymous app pages minus purgeable pages, plus wired and compressed
        // storage. Reclaimable file cache is excluded, as in Activity Monitor.
        let appPages = UInt64(vm.internal_page_count) > UInt64(vm.purgeable_count)
            ? UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) : 0
        let pageSize = UInt64(getpagesize())
        snapshot.memoryApps = appPages * pageSize
        snapshot.memoryWired = UInt64(vm.wire_count) * pageSize
        snapshot.memoryCompressed = UInt64(vm.compressor_page_count) * pageSize
        let usedPages = appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        return (min(total, usedPages * UInt64(getpagesize())), total)
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

    nonisolated private static func readProcesses(includeFootprint: Bool) -> [(pid: Int32, name: String, cpuAbsoluteTime: UInt64, footprint: UInt64?)] {
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

    nonisolated private static func readPhysicalFootprint(for pid: pid_t) -> UInt64? {
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
