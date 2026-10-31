import AppKit
import Darwin
import IOKit

// Accessed exclusively by MetricsStore's serial sampling queue.
final class MetricsSampler: @unchecked Sendable {
    struct Result: @unchecked Sendable {
        var snapshot: MetricSnapshot
        var selectedPID: Int32?
        var detail: (performance: Double, efficiency: Double)?
        var gpuAvailable: Bool?
    }
    private var snapshot = MetricSnapshot()
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()
    private var activeMetric: Metric?
    private var keepsDetailsWarm = false
    private var selectedCPUPID: Int32?
    private var selectedCPUDetail: (performance: Double, efficiency: Double)?
    private var gpuAttributionAvailable: Bool?
    private var splitCache: [Int32: (start: UInt64, performance: Double, efficiency: Double, time: Double)] = [:]
    private var cpuDetailBaseline: (pid: Int32, start: UInt64, total: UInt64, performance: UInt64, time: Double)?
    private var gpuBaseline: [UInt64: (pid: Int32, time: UInt64)] = [:]
    private var gpuSampleTime: Double?
    private var previousProcesses: [Int32: UInt64] = [:]
    private var processNames: [Int32: (seconds: UInt64, microseconds: UInt64, name: String)] = [:]
    private var previousProcessSample = ProcessInfo.processInfo.systemUptime
    private var previousProcessorTicks: [ProcessorTicks] = []
    private lazy var coreTypes = readCoreTypes()
    private let logicalCoreCount = max(1, ProcessInfo.processInfo.processorCount)
    private let cpuNanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(max(1, info.denom))
    }()
    private struct ProcessorTicks { let user: UInt32; let system: UInt32; let idle: UInt32; let nice: UInt32 }

    func collect(active: Metric?, warm: Bool, selected: Int32?) -> Result {
        activeMetric = active
        keepsDetailsWarm = warm
        if selectedCPUPID != selected {
            selectedCPUPID = selected
            cpuDetailBaseline = nil
            selectedCPUDetail = nil
        }
        snapshot.cpuPercent = readSystemCPU()
        let memory = readMemory()
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.memoryPercent = memory.total == 0 ? 0 : Double(memory.used) / Double(memory.total) * 100
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used; snapshot.swapTotal = swap.xsu_total
        }
        snapshot.gpuPercent = readGPUUtilization()
        snapshot.updatedAt = Date()
        sampleSelectedCPU()
        if warm {
            sampleGPUProcesses()
            let start = ProcessInfo.processInfo.systemUptime
            let processes = readProcesses(includeFootprint: true)
            let now = (start + ProcessInfo.processInfo.systemUptime) / 2
            applyProcessSample(processes, sampledAt: now, for: .cpu)
            applyProcessSample(processes, sampledAt: now, for: .memory)
        } else {
            snapshot.processUsage.removeAll()
            previousProcesses.removeAll()
            processNames.removeAll()
            gpuBaseline.removeAll()
            gpuSampleTime = nil
            splitCache.removeAll()
        }
        return Result(snapshot: snapshot, selectedPID: selected, detail: selectedCPUDetail, gpuAvailable: gpuAttributionAvailable)
    }
    private func sampleSelectedCPU() {
        guard activeMetric == .cpu, let pid = selectedCPUPID else { return }
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { selectedCPUDetail = nil; cpuDetailBaseline = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if cpuDetailBaseline == nil, let cached = splitCache[pid],
           cached.start == usage.ri_proc_start_abstime, now - cached.time <= 10 {
            selectedCPUDetail = (cached.performance, cached.efficiency)
        }
        let total = usage.ri_user_time + usage.ri_system_time
        let performance = usage.ri_user_ptime + usage.ri_system_ptime
        defer { cpuDetailBaseline = (pid, usage.ri_proc_start_abstime, total, performance, now) }
        guard let prior = cpuDetailBaseline, prior.pid == pid, prior.start == usage.ri_proc_start_abstime,
              total >= prior.total, performance >= prior.performance else { return }
        let scale = cpuNanosecondsPerTick * 100 / (max(0.001, now - prior.time) * 1_000_000_000 * Double(logicalCoreCount))
        let delta = total - prior.total
        let p = min(delta, performance - prior.performance)
        let detail = (Double(p) * scale, Double(delta - p) * scale)
        selectedCPUDetail = detail
        splitCache = splitCache.filter { now - $0.value.time <= 10 }
        splitCache[pid] = (usage.ri_proc_start_abstime, detail.0, detail.1, now)
    }

    private func sampleGPUProcesses() {
        var roots: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &roots) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(roots) }
        var current: [UInt64: (pid: Int32, time: UInt64)] = [:]
        var names: [Int32: String] = [:]
        var root = IOIteratorNext(roots)
        while root != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                var entry = IOIteratorNext(children)
                while entry != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       creator.hasPrefix("pid "),
                       let comma = creator.firstIndex(of: ","),
                       let pid = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]),
                       let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                        var id: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS {
                            let time = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                            current[id] = (pid, time)
                            names[pid] = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(root)
            root = IOIteratorNext(roots)
        }
        gpuAttributionAvailable = !current.isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        defer { gpuBaseline = current; gpuSampleTime = now }
        guard let priorTime = gpuSampleTime else { return }
        var deltas: [Int32: UInt64] = [:]
        for (id, sample) in current {
            guard let prior = gpuBaseline[id], prior.pid == sample.pid, sample.time >= prior.time else { continue }
            deltas[sample.pid, default: 0] += sample.time - prior.time
        }
        snapshot.processUsage[.gpu] = deltas.map { pid, delta in
            let percent = Double(delta) / 1_000_000_000 / max(0.001, now - priorTime) * 100
            return ProcessUsage(pid: pid, name: names[pid] ?? "Process", value: percent,
                                detail: String(format: "%.1f%%", percent), icon: nil)
        }.sorted { $0.value > $1.value }
    }

    private func applyProcessSample(
        _ current: [(pid: Int32, name: String, cpuAbsoluteTime: UInt64, footprint: UInt64?)],
        sampledAt now: TimeInterval,
        for metric: Metric
    ) {
        let elapsed = max(0.001, now - previousProcessSample)
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
                return (process.pid, process.name, percent, byteFormatter.string(fromByteCount: Int64(footprint)))
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

        if metric == .cpu {
            previousProcesses = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0.cpuAbsoluteTime) })
            previousProcessSample = now
        }
        snapshot.processUsage[metric] = usage
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
        if keepsDetailsWarm { snapshot.cpuCoreGroups = makeCoreGroups(from: perCoreUsage) }
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
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
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

    private func readProcesses(includeFootprint: Bool) -> [(pid: Int32, name: String, cpuAbsoluteTime: UInt64, footprint: UInt64?)] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 16)
        let actual = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        let livePIDs = pids.prefix(Int(actual) / MemoryLayout<pid_t>.size)
        let live = Set(livePIDs)
        processNames = processNames.filter { live.contains($0.key) }
        return livePIDs.compactMap { pid in
            guard pid > 0 else { return nil }
            var identity = proc_bsdinfo()
            let identitySize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, identitySize) == identitySize,
                  identity.pbi_uid == uid_t(getuid()) else { return nil }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { return nil }
            let seconds = UInt64(identity.pbi_start_tvsec)
            let microseconds = UInt64(identity.pbi_start_tvusec)
            let name: String
            if let cached = processNames[pid], cached.seconds == seconds, cached.microseconds == microseconds {
                name = cached.name
            } else {
                previousProcesses.removeValue(forKey: pid)
                var nameBuffer = [CChar](repeating: 0, count: 256)
                guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { return nil }
                name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                processNames[pid] = (seconds, microseconds, name)
            }
            let footprint: UInt64? = includeFootprint ? usage.ri_phys_footprint : nil
            return (pid, name, usage.ri_user_time + usage.ri_system_time, footprint)
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
