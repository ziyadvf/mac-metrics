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

    @Published private(set) var selectedCPUDetail: (performance: Double, efficiency: Double)?
    var selectedCPUPID: Int32? {
        didSet {
            selectedCPUDetail = nil
            refresh()
        }
    }
    private var engagement: Double = 0
    private var lastOpen: Double?
    private var warmUntil: Double = 0
    private var warmDuration: Double = 60
    private var keepsDetailsWarm: Bool { activeMetric != nil || ProcessInfo.processInfo.systemUptime < warmUntil }
    @Published private(set) var gpuAttributionAvailable: Bool?

    private let logicalCoreCount = max(1, ProcessInfo.processInfo.processorCount)
    private var timer: Timer?
    private var idleCleanupTask: Task<Void, Never>?
    private var refreshInterval: TimeInterval
    private var processIcons: [Int32: NSImage?] = [:]
    private lazy var coreTypes = readCoreTypes()
    var coreLayout: [CPUCoreGroup] { makeCoreGroups(from: Array(repeating: 0, count: logicalCoreCount)) }

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
        timer?.invalidate()
        let interval = activeMetric == nil ? max(5, refreshInterval) : max(3, refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(1, interval * 0.2)
    }

    func show(_ metric: Metric) {
        idleCleanupTask?.cancel()
        idleCleanupTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        if let lastOpen { engagement *= exp(-(now - lastOpen) / 120) }
        engagement = min(6, engagement + 1)
        lastOpen = now
        warmDuration = min(300, 30 + engagement * 30)
        activeMetric = metric
        scheduleRefreshTimer()
        refresh()
    }

    func hide(_ metric: Metric) {
        guard activeMetric == metric else { return }
        activeMetric = nil
        warmUntil = ProcessInfo.processInfo.systemUptime + warmDuration
        selectedCPUPID = nil
        scheduleRefreshTimer()
        idleCleanupTask?.cancel()
        let retention = warmDuration
        idleCleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(retention)) } catch { return }
            guard let self, self.activeMetric == nil else { return }
            self.processIcons.removeAll()
            self.snapshot.processUsage.removeAll()
            self.refresh()
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

    func refreshProcesses(for metric: Metric) { refresh() }

    func processIcon(for pid: Int32) -> NSImage? {
        if let cachedIcon = processIcons[pid] { return cachedIcon }
        if processIcons.keys.contains(pid) { return nil }

        let applicationIcon = NSRunningApplication(processIdentifier: pid)?.icon
        let icon = applicationIcon ?? processApplicationBundlePath(for: pid).map {
            NSWorkspace.shared.icon(forFile: $0)
        }
        if processIcons.count >= 64 { processIcons.removeAll(keepingCapacity: true) }
        let thumbnail: NSImage? = icon.map { source in
            let image = NSImage(size: NSSize(width: 24, height: 24))
            image.lockFocus()
            source.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24), from: .zero, operation: .sourceOver, fraction: 1)
            image.unlockFocus()
            return image
        }
        processIcons[pid] = .some(thumbnail)
        return thumbnail
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

    private let sampler = MetricsSampler()
    private let samplingQueue = DispatchQueue(label: "dev.ziyadvf.macmetrics.sampling", qos: .background)
    private var sampling = false
    private var refreshPending = false

    private func refresh() {
        guard !sampling else { refreshPending = true; return }
        sampling = true
        let active = activeMetric
        let warm = keepsDetailsWarm
        let selected = selectedCPUPID
        let qos: DispatchQoS = active == nil ? .background : .utility
        let sampler = self.sampler
        samplingQueue.async(qos: qos, flags: .enforceQoS) { [weak self] in
            let result = autoreleasepool { sampler.collect(active: active, warm: warm, selected: selected) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampling = false
                self.objectWillChange.send()
                self.batchingSnapshot = true
                var snapshot = result.snapshot
                if !self.keepsDetailsWarm { snapshot.processUsage.removeAll() }
                self.snapshot = snapshot
                self.batchingSnapshot = false
                if self.selectedCPUPID == result.selectedPID {
                    self.selectedCPUDetail = result.detail
                }
                if self.gpuAttributionAvailable != result.gpuAvailable { self.gpuAttributionAvailable = result.gpuAvailable }
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
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

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
