import Foundation
import Metal
import CryptoKit
import Observation
import SwiftUI
import os

enum LogLevel: Int, Comparable {
    case debug, info, warn, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var tag: String { ["DEBUG", "INFO ", "WARN ", "ERROR"][rawValue] }
    var tint: Color { [Color.white.opacity(0.45), Palette.sky, Palette.orange, Palette.pink][rawValue] }
}

struct LogLine: Identifiable {
    let id: Int
    let elapsed: Double
    let level: LogLevel
    let source: String
    let text: String
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Thread-safe running total that workers add to and the UI samples.
final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0
    private var errorCount = 0
    private var text = ""
    func add(_ v: Double) { lock.lock(); sum += v; lock.unlock() }
    func addErrors(_ n: Int) { lock.lock(); errorCount += n; lock.unlock() }
    func setNote(_ s: String) { lock.lock(); text = s; lock.unlock() }
    var total: Double { lock.lock(); defer { lock.unlock() }; return sum }
    var errors: Int { lock.lock(); defer { lock.unlock() }; return errorCount }
    var note: String { lock.lock(); defer { lock.unlock() }; return text }
}

typealias LogFn = @Sendable (LogLevel, String, String) -> Void

enum StressWorkers {
    /// One hashing + floating point loop per thread. The meter counts megabytes hashed.
    static func cpu(stop: StopFlag, meter: Meter) {
        var buf = [UInt8](repeating: 0xA5, count: 1 << 20)
        var x = 1.0001
        while !stop.isSet {
            let digest = SHA256.hash(data: buf)
            buf[Int(x) & 0xFFFF] = digest.withUnsafeBytes { $0[0] }
            for i in 0..<60_000 { x = (x * 1.0000001 + Double(i & 7)).squareRoot() }
            meter.add(1)
        }
    }

    /// Fills memory with a pattern and reads it back. The meter counts bytes touched; errors are mismatches.
    static func memory(targetBytes: Int, stop: StopFlag, meter: Meter, log: LogFn) {
        let chunk = 64 << 20, words = chunk / 8
        let count = max(1, targetBytes / chunk)
        var chunks: [UnsafeMutablePointer<UInt64>] = []
        for _ in 0..<count where !stop.isSet { chunks.append(.allocate(capacity: words)) }
        defer { chunks.forEach { $0.deallocate() } }
        log(.info, "MEM", "Allocated \(chunks.count) × 64 MB = \(bytes(Int64(chunks.count * chunk)))")
        var pass: UInt64 = 0
        while !stop.isSet {
            pass += 1
            var bad = 0
            for (ci, p) in chunks.enumerated() where !stop.isSet {
                let seed = pass &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(ci)
                for j in 0..<words { p[j] = seed &+ UInt64(j) }
                for j in 0..<words where p[j] != seed &+ UInt64(j) { bad += 1 }
                meter.add(Double(chunk * 2))
            }
            if bad > 0 { meter.addErrors(bad); log(.error, "MEM", "Pass \(pass): \(bad) mismatched words. Memory returned different data than was written.") }
            else if !stop.isSet { log(.debug, "MEM", "Pass \(pass) verified, no errors") }
        }
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(texture2d<float, access::write> out [[texture(0)]], constant float &seed [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 c = (float2(gid) / float2(out.get_width(), out.get_height()) - float2(0.7, 0.5)) * 2.6;
        float2 z = float2(seed * 0.001, 0.0);
        float acc = 0.0;
        for (int i = 0; i < 700; i++) {
            z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
            if (dot(z, z) > 16.0) { z = fract(z); }
            acc += sin(z.x) * cos(z.y);
        }
        out.write(float4(acc, z.x, z.y, 1.0), gid);
    }
    """

    /// Runs a heavy compute kernel back to back. The meter counts megapixels shaded.
    static func gpu(stop: StopFlag, meter: Meter, log: LogFn) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { log(.error, "GPU", "No Metal device available"); return }
        let side = 2048
        do {
            let lib = try device.makeLibrary(source: shader, options: nil)
            guard let fn = lib.makeFunction(name: "burn") else { log(.error, "GPU", "Shader function missing"); return }
            let pipeline = try device.makeComputePipelineState(function: fn)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
            desc.usage = [.shaderWrite]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { log(.error, "GPU", "Could not create the work texture"); return }
            log(.info, "GPU", "\(device.name): compute kernel compiled, \(side)×\(side) target, 700 iterations per pixel")
            var seed: Float = 0
            while !stop.isSet {
                seed += 1
                guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { continue }
                enc.setComputePipelineState(pipeline)
                enc.setTexture(tex, index: 0)
                enc.setBytes(&seed, length: MemoryLayout<Float>.size, index: 0)
                enc.dispatchThreads(MTLSize(width: side, height: side, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
                if let e = cmd.error { meter.addErrors(1); log(.error, "GPU", "Command buffer failed: \(e.localizedDescription)") }
                else { meter.add(Double(side * side) / 1_000_000) }
            }
        } catch { log(.error, "GPU", "Shader setup failed: \(error.localizedDescription)") }
    }

    /// Writes and reads back a 1 GB uncached file. The meter counts bytes moved; its note holds the latest speeds.
    static func disk(maxPasses: Int, stop: StopFlag, meter: Meter, log: LogFn) {
        let free = Disk.volume().free
        guard free > 6_000_000_000 else { log(.warn, "DISK", "Skipped: only \(bytes(free)) free, the test needs 6 GB of headroom"); return }
        let path = NSTemporaryDirectory() + "cleansilicon-stress-\(getpid()).bin"
        let block = 16 << 20, blocks = 64
        let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 16384)
        let back = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 16384)
        defer { buf.deallocate(); back.deallocate(); unlink(path) }
        arc4random_buf(buf, block)
        var pass = 0
        while !stop.isSet, pass < maxPasses {
            pass += 1
            let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
            guard fd >= 0 else { log(.error, "DISK", "Could not create test file: \(String(cString: strerror(errno)))"); return }
            _ = fcntl(fd, F_NOCACHE, 1)
            var t = Date(), ok = true
            for _ in 0..<blocks where !stop.isSet {
                if write(fd, buf, block) != block { ok = false; meter.addErrors(1); log(.error, "DISK", "Short write: \(String(cString: strerror(errno)))"); break }
                meter.add(Double(block))
            }
            _ = fcntl(fd, F_FULLFSYNC)
            let wrote = lseek(fd, 0, SEEK_CUR)
            let wSpeed = Double(wrote) / 1_000_000 / max(Date().timeIntervalSince(t), 0.001)
            lseek(fd, 0, SEEK_SET)
            t = Date()
            var readBytes = 0, mismatched = 0
            while ok, !stop.isSet {
                let n = read(fd, back, block)
                if n <= 0 { break }
                if memcmp(buf, back, n) != 0 { mismatched += 1 }
                readBytes += n
                meter.add(Double(n))
            }
            let rSpeed = Double(readBytes) / 1_000_000 / max(Date().timeIntervalSince(t), 0.001)
            close(fd)
            if mismatched > 0 { meter.addErrors(mismatched); log(.error, "DISK", "Pass \(pass): \(mismatched) blocks read back differently than written") }
            if readBytes > 0 {
                meter.setNote(String(format: "W %.0f · R %.0f MB/s", wSpeed, rSpeed))
                log(.info, "DISK", String(format: "Pass %d/%d: write %.0f MB/s, read %.0f MB/s, %@ verified", pass, maxPasses, wSpeed, rSpeed, bytes(Int64(readBytes))))
            }
        }
    }
}

enum StressComponent: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", memory = "Memory", disk = "Disk"
    var id: String { rawValue }
    var symbol: String { ["CPU": "cpu.fill", "GPU": "square.stack.3d.up.fill", "Memory": "memorychip.fill", "Disk": "internaldrive.fill"][rawValue]! }
    var tint: Color { ["CPU": Palette.sky, "GPU": Palette.mint, "Memory": Palette.violet, "Disk": Palette.orange][rawValue]! }
    var blurb: String {
        switch self {
        case .cpu: "Hashing and floating point on every core"
        case .gpu: "Back-to-back Metal compute kernel"
        case .memory: "Pattern write and verify across free RAM"
        case .disk: "1 GB uncached write, read and verify"
        }
    }
}

@MainActor @Observable
final class StressModel {
    var selected: Set<StressComponent> = Set(StressComponent.allCases)
    var durationSec = 60
    var running = false
    var stopping = false
    var elapsed = 0.0
    var lines: [LogLine] = []
    var minLevel: LogLevel = .debug
    var live: [StressComponent: String] = [:]
    var tempTrace: [Double] = []
    var powerTrace: [Double] = []
    var summary: [SpecRow] = []
    var logURL: URL?
    var csvURL: URL?

    @ObservationIgnored private var stop = StopFlag()
    @ObservationIgnored private var meters: [StressComponent: Meter] = [:]
    @ObservationIgnored private var lastTotals: [StressComponent: Double] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var logHandle: FileHandle?
    @ObservationIgnored private var csvHandle: FileHandle?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var group = DispatchGroup()
    @ObservationIgnored private weak var monitor: SystemMonitor?
    @ObservationIgnored private var lastThermal: ProcessInfo.ThermalState = .nominal
    @ObservationIgnored private var lastThrottleWarn = -100.0
    @ObservationIgnored private var peakTemp = 0.0
    @ObservationIgnored private var peakW = 0.0
    @ObservationIgnored private var minPMHz = Double.infinity
    @ObservationIgnored private var sumW = 0.0
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var cpuRates: [Double] = []
    @ObservationIgnored private var pressure: DispatchSourceMemoryPressure?
    @ObservationIgnored private let oslog = Logger(subsystem: "com.cleansilicon.app", category: "stress")
    @ObservationIgnored private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; f.timeZone = .current; return f
    }()

    var visible: [LogLine] { lines.filter { $0.level >= minLevel }.suffix(400) }
    var progress: Double { durationSec == 0 ? 0 : min(1, elapsed / Double(durationSec)) }

    func log(_ level: LogLevel, _ source: String, _ text: String) {
        let e = running || stopping ? Date().timeIntervalSince(started) : elapsed
        lines.append(LogLine(id: nextID, elapsed: e, level: level, source: source, text: text))
        nextID += 1
        if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
        let row = "\(stamp.string(from: Date())) [+\(String(format: "%07.2f", e))s] [\(level.tag)] [\(source)] \(text)\n"
        logHandle?.write(Data(row.utf8))
        switch level {
        case .debug: oslog.debug("[\(source, privacy: .public)] \(text, privacy: .public)")
        case .info: oslog.info("[\(source, privacy: .public)] \(text, privacy: .public)")
        case .warn: oslog.warning("[\(source, privacy: .public)] \(text, privacy: .public)")
        case .error: oslog.error("[\(source, privacy: .public)] \(text, privacy: .public)")
        }
    }

    func start(monitor: SystemMonitor, machine: String, chip: String) {
        guard !running, !stopping, !selected.isEmpty else { return }
        self.monitor = monitor
        stop = StopFlag(); group = DispatchGroup()
        meters = [:]; lastTotals = [:]; live = [:]; summary = []; lines = []; tempTrace = []; powerTrace = []; cpuRates = []
        peakTemp = 0; peakW = 0; minPMHz = .infinity; sumW = 0; ticks = 0; elapsed = 0; lastThrottleWarn = -100
        started = Date()
        lastThermal = monitor.snap.thermal

        let dir = Disk.home.appendingPathComponent("Library/Logs/Clean Silicon")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let base = dir.appendingPathComponent("stress-\(f.string(from: started))")
        logURL = base.appendingPathExtension("log"); csvURL = base.appendingPathExtension("csv")
        for u in [logURL!, csvURL!] { FileManager.default.createFile(atPath: u.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: logURL!)
        csvHandle = try? FileHandle(forWritingTo: csvURL!)
        csvHandle?.write(Data("elapsed_s,cpu_pct,p_mhz,e_mhz,cpu_temp_c,cpu_temp_max_c,battery_temp_c,ssd_temp_c,system_w,adapter_w,gpu_w,gpu_pct,mem_pct,swap_bytes,thermal,fan_rpm,cpu_mb_s,gpu_mpix_s,mem_gb_s,disk_mb_s\n".utf8))

        withAnimation(.spring) { running = true }
        let s = monitor.snap
        let order = StressComponent.allCases.filter(selected.contains)
        log(.info, "SYS", "Stress test started: \(order.map(\.rawValue).joined(separator: " + ")) for \(durationSec) s")
        log(.info, "SYS", "\(machine), \(chip), \(Int64(s.memTotal).formatted(.byteCount(style: .memory))) RAM, \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log(.info, "SYS", "Baseline: CPU \(degrees(s.cpuTemp))C, \(String(format: "%.1f", s.systemW ?? 0)) W, thermal \(Self.name(s.thermal)), \(s.battery.plugged ? "on charger" : "on battery \(s.battery.percent)%")")
        log(.info, "SYS", "Log file: \(logURL!.path)")

        let stop = stop
        let sink: LogFn = { [weak self] level, source, text in DispatchQueue.main.async { self?.log(level, source, text) } }
        func launch(_ c: StressComponent, _ name: String, _ body: @escaping @Sendable (Meter) -> Void) {
            let meter = meters[c] ?? Meter()
            meters[c] = meter
            group.enter()
            let group = group
            let t = Thread { body(meter); group.leave() }
            t.name = name; t.qualityOfService = .userInitiated; t.stackSize = 4 << 20
            t.start()
        }
        if selected.contains(.cpu) {
            let n = ProcessInfo.processInfo.activeProcessorCount
            log(.info, "CPU", "Starting \(n) worker threads (SHA-256 over 1 MB blocks + square roots)")
            for i in 0..<n { launch(.cpu, "stress-cpu-\(i)") { StressWorkers.cpu(stop: stop, meter: $0) } }
        }
        if selected.contains(.gpu) { launch(.gpu, "stress-gpu") { StressWorkers.gpu(stop: stop, meter: $0, log: sink) } }
        if selected.contains(.memory) {
            let free = Double(s.memTotal) - Double(s.memUsed)
            let target = max(256 << 20, min(Int(s.memTotal / 2), Int(free * 0.7)))
            log(.info, "MEM", "Target \(bytes(Int64(target))) (\(bytes(Int64(free))) was not in use)")
            launch(.memory, "stress-mem") { StressWorkers.memory(targetBytes: target, stop: stop, meter: $0, log: sink) }
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
            src.setEventHandler { [weak self] in self?.log(.error, "MEM", "macOS reported critical memory pressure; stopping to protect the system"); self?.finish(reason: "memory pressure") }
            src.resume(); pressure = src
        }
        if selected.contains(.disk) {
            let passes = max(1, min(6, durationSec / 30))
            log(.info, "DISK", "Up to \(passes) pass\(passes == 1 ? "" : "es") of 1 GB (limited to spare SSD wear)")
            launch(.disk, "stress-disk") { StressWorkers.disk(maxPasses: passes, stop: stop, meter: $0, log: sink) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    static func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown" }
    }

    private func tick() {
        guard running, let s = monitor?.snap else { return }
        elapsed = Date().timeIntervalSince(started)
        var rate: [StressComponent: Double] = [:]
        for (c, m) in meters { let t = m.total; rate[c] = t - (lastTotals[c] ?? 0); lastTotals[c] = t }
        if let r = rate[.cpu] { live[.cpu] = String(format: "%.0f MB/s", r); cpuRates.append(r) }
        if let r = rate[.gpu] { live[.gpu] = String(format: "%.0f Mpx/s", r) }
        if let r = rate[.memory] { live[.memory] = String(format: "%.1f GB/s", r / 1e9) }
        if let m = meters[.disk] { live[.disk] = m.note.isEmpty ? String(format: "%.0f MB/s", (rate[.disk] ?? 0) / 1e6) : m.note }

        let w = s.systemW ?? 0
        if let t = s.cpuTemp { tempTrace.append(t); peakTemp = max(peakTemp, s.cpuTempMax ?? t) }
        powerTrace.append(w); peakW = max(peakW, w); sumW += w; ticks += 1
        if selected.contains(.cpu), s.pMHz > 0, elapsed > 4 { minPMHz = min(minPMHz, s.pMHz) }

        let fan = s.fans?.first.map { String(Int($0.rpm)) } ?? ""
        let f1 = { (v: Double?) in v.map { String(format: "%.1f", $0) } ?? "" }
        let cols: [String] = [String(format: "%.1f", elapsed), String(format: "%.1f", s.cpuTotal * 100), String(format: "%.0f", s.pMHz), String(format: "%.0f", s.eMHz),
                    f1(s.cpuTemp), f1(s.cpuTempMax), f1(s.batteryTemp), f1(s.ssdTemp), f1(s.systemW), f1(s.adapterW), f1(s.gpuW),
                    String(format: "%.1f", s.gpuUsage * 100), String(format: "%.1f", s.memFraction * 100), "\(s.swapUsed)", Self.name(s.thermal), fan,
                    f1(rate[.cpu]), f1(rate[.gpu]), f1(rate[.memory].map { $0 / 1e9 }), f1(rate[.disk].map { $0 / 1e6 })]
        csvHandle?.write(Data((cols.joined(separator: ",") + "\n").utf8))
        log(.debug, "TELEM", String(format: "cpu %.0f%% · %@ %.2f GHz · %@ %.2f GHz · %@C (max %@C) · %.1f W · gpu %.0f%% · mem %.0f%% · thermal %@",
                                    s.cpuTotal * 100, monitor?.engine.pName ?? "P", s.pMHz / 1000, monitor?.engine.eName ?? "E", s.eMHz / 1000,
                                    degrees(s.cpuTemp), degrees(s.cpuTempMax), w, s.gpuUsage * 100, s.memFraction * 100, Self.name(s.thermal)))

        if s.thermal != lastThermal {
            log(s.thermal.rawValue > lastThermal.rawValue ? .warn : .info, "THERM", "Thermal state changed: \(Self.name(lastThermal)) → \(Self.name(s.thermal))")
            lastThermal = s.thermal
        }
        if selected.contains(.cpu), let pMax = monitor?.engine.pTable.max(), s.pMHz > 0, s.pMHz < pMax * 0.8, s.cpuTotal > 0.9, elapsed - lastThrottleWarn > 10 {
            lastThrottleWarn = elapsed
            log(.warn, "CPU", String(format: "Clock held at %.2f GHz, %.0f%% of the %.2f GHz maximum, under full load: the chip is limiting itself for heat or power", s.pMHz / 1000, s.pMHz / pMax * 100, pMax / 1000))
        }
        for (c, m) in meters where m.errors > 0 { live[c] = (live[c] ?? "") + " · \(m.errors) err" }

        if (s.cpuTempMax ?? 0) >= 110 { log(.error, "THERM", "Hottest core reached \(degrees(s.cpuTempMax))C; stopping for safety"); finish(reason: "temperature limit") }
        else if s.thermal == .critical { log(.error, "THERM", "macOS reports critical thermal state; stopping for safety"); finish(reason: "critical thermal state") }
        else if elapsed >= Double(durationSec) { finish(reason: "duration reached") }
    }

    func finish(reason: String) {
        guard running else { return }
        timer?.invalidate(); timer = nil
        pressure?.cancel(); pressure = nil
        stop.set()
        withAnimation(.spring) { running = false; stopping = true }
        log(.info, "SYS", "Stopping (\(reason)); waiting for workers to finish")
        group.notify(queue: .main) { [weak self] in self?.summarise(reason: reason) }
    }

    private func summarise(reason: String) {
        let secs = max(elapsed, 1)
        var rows: [SpecRow] = [SpecRow(label: "Ran for", value: String(format: "%.0f s (%@)", elapsed, reason))]
        if let m = meters[.cpu] {
            rows.append(SpecRow(label: "CPU throughput", value: String(format: "%.0f MB/s average", m.total / secs)))
            if cpuRates.count >= 20 {
                let head = cpuRates.dropFirst(2).prefix(8).reduce(0, +) / 8, tail = cpuRates.suffix(8).reduce(0, +) / 8
                if head > 0 { rows.append(SpecRow(label: "CPU sustained", value: String(format: "%.0f%% of starting speed", tail / head * 100))) }
            }
            if minPMHz.isFinite { rows.append(SpecRow(label: "Lowest clock under load", value: String(format: "%.2f GHz", minPMHz / 1000))) }
        }
        if let m = meters[.gpu] { rows.append(SpecRow(label: "GPU throughput", value: String(format: "%.0f Mpx/s average, %d errors", m.total / secs, m.errors))) }
        if let m = meters[.memory] { rows.append(SpecRow(label: "Memory", value: String(format: "%.1f GB/s, %@ checked, %d errors", m.total / secs / 1e9, bytes(Int64(m.total)), m.errors))) }
        if let m = meters[.disk] { rows.append(SpecRow(label: "Disk", value: (m.note.isEmpty ? "no complete pass" : m.note) + ", \(m.errors) errors")) }
        rows.append(SpecRow(label: "Peak temperature", value: peakTemp > 0 ? String(format: "%.1f °C", peakTemp) : "—"))
        rows.append(SpecRow(label: "Power", value: String(format: "%.1f W peak, %.1f W average", peakW, ticks > 0 ? sumW / Double(ticks) : 0)))
        let errors = meters.values.reduce(0) { $0 + $1.errors }
        rows.append(SpecRow(label: "Verdict", value: errors == 0 ? "No errors detected" : "\(errors) errors: see log"))
        for r in rows { log(errors > 0 && r.label == "Verdict" ? .error : .info, "RESULT", "\(r.label): \(r.value)") }
        try? logHandle?.close(); try? csvHandle?.close(); logHandle = nil; csvHandle = nil
        withAnimation(.spring(duration: 0.5)) { summary = rows; stopping = false }
    }
}
