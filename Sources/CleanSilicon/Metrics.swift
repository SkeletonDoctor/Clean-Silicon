import Foundation
import IOKit
import Observation
import SwiftUI

struct CoreStat: Identifiable {
    let id: Int
    var label: String
    var isPerformance: Bool
    var usage: Double      // 0...1
    var mhz: Double        // average frequency while active
}

struct BatteryInfo {
    var present = false
    var percent = 0
    var cycles = 0
    var healthPct = 0.0
    var tempC = 0.0
    var charging = false
    var plugged = false
    var adapterW = 0
    var designmAh = 0
    var maxmAh = 0
    var volts = 0.0
    var flowW = 0.0        // + charging, - discharging
}

struct MetricsSnapshot {
    var cpuTotal = 0.0
    var cores: [CoreStat] = []
    var eMHz = 0.0
    var pMHz = 0.0
    var gpuUsage = 0.0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var systemW: Double?   // whole-machine draw
    var adapterW: Double?  // power coming in from the charger
    var cpuW: Double?
    var gpuW: Double?
    var battery = BatteryInfo()
    var thermal: ProcessInfo.ThermalState = .nominal
    var cpuTemp: Double?
    var cpuTempMax: Double?
    var batteryTemp: Double?
    var ssdTemp: Double?
    var netDown = 0.0      // bytes per second
    var netUp = 0.0
    var fans: [FanStat]?
    var topCPU: [ProcStat] = []
    var topMemory: [ProcStat] = []

    var memUsed: UInt64 { memApp + memWired + memCompressed }
    var memFraction: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
    return Int(v)
}

/// Reads live hardware counters. Not thread safe: use from one queue.
final class MetricsEngine {
    let eTable: [Double]   // MHz steps, efficiency cluster
    let pTable: [Double]   // MHz steps, performance cluster
    let pName: String
    let eName: String

    private let sampler = IOReportSampler(groups: [
        ("Energy Model", nil),
        ("CPU Stats", "CPU Core Performance States"),
        ("GPU Stats", "GPU Performance States"),
    ])
    private var prevTicks: [UInt32]?
    private let temps = TemperatureSensors()
    private let smc = SMC()
    private var prevNet: (down: UInt64, up: UInt64, time: TimeInterval)?
    private var tick = 0
    private var procs: (cpu: [ProcStat], memory: [ProcStat]) = ([], [])

    init() {
        eTable = Self.freqTable("voltage-states1-sram")
        pTable = Self.freqTable("voltage-states5-sram")
        let p = sysctlString("hw.perflevel0.name"), e = sysctlString("hw.perflevel1.name")
        pName = p.isEmpty ? "Performance" : p
        eName = e.isEmpty ? "Efficiency" : e
    }

    static func freqTable(_ key: String) -> [Double] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while true {
            let entry = IOIteratorNext(it)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            guard String(cString: name) == "pmgr" else { continue }
            guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return [] }
            var out: [Double] = []
            var i = 0
            while i + 8 <= data.count {
                let raw = data.subdata(in: i..<i + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                // Older chips report Hz, newer ones kHz.
                out.append(raw > 10_000_000 ? Double(raw) / 1_000_000 : Double(raw) / 1000)
                i += 8
            }
            return out
        }
        return []
    }

    func read() -> MetricsSnapshot {
        var s = MetricsSnapshot()
        s.thermal = ProcessInfo.processInfo.thermalState
        readCPU(&s)
        readMemory(&s)
        readBattery(&s)
        readIOReport(&s)
        if let t = temps?.read() {
            s.cpuTemp = t.cpu; s.cpuTempMax = t.cpuMax; s.batteryTemp = t.battery; s.ssdTemp = t.ssd
            if let b = t.battery { s.battery.tempC = b }
        }
        s.fans = smc?.fans()
        let net = SystemProbe.networkBytes(), now = ProcessInfo.processInfo.systemUptime
        if let p = prevNet, now > p.time, net.down >= p.down, net.up >= p.up {
            s.netDown = Double(net.down - p.down) / (now - p.time)
            s.netUp = Double(net.up - p.up) / (now - p.time)
        }
        prevNet = (net.down, net.up, now)
        if tick % 3 == 0 { procs = SystemProbe.processes() }
        tick += 1
        s.topCPU = procs.cpu; s.topMemory = procs.memory
        return s
    }

    private func readCPU(_ s: inout MetricsSnapshot) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        if let p = prevTicks {
            let d = zip(t, p).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            if total > 0 { s.cpuTotal = (d[0] + d[1] + d[3]) / total }
        }
        prevTicks = t
    }

    private func readMemory(_ s: inout MetricsSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(stats.purgeable_count)
            s.memApp = (UInt64(stats.internal_page_count) &- purgeable) * page
            s.memWired = UInt64(stats.wire_count) * page
            s.memCompressed = UInt64(stats.compressor_page_count) * page
            s.memCached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swapUsed = swap.xsu_used }
    }

    private func readBattery(_ s: inout MetricsSnapshot) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var ref: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = ref?.takeRetainedValue() as? [String: Any] else { return }
        func int(_ k: String, in dict: [String: Any]? = nil) -> Int { ((dict ?? d)[k] as? NSNumber)?.intValue ?? 0 }

        var b = BatteryInfo()
        b.present = (d["BatteryInstalled"] as? Bool) ?? true
        b.percent = int("CurrentCapacity")
        b.cycles = int("CycleCount")
        let data = d["BatteryData"] as? [String: Any]
        func either(_ k: String) -> Int { let v = int(k); return v != 0 ? v : int(k, in: data ?? [:]) }
        b.designmAh = either("DesignCapacity")
        b.maxmAh = either("AppleRawMaxCapacity")
        if b.designmAh > 0 { b.healthPct = min(100, Double(b.maxmAh) / Double(b.designmAh) * 100) }
        b.tempC = Double(max(either("Temperature"), either("VirtualTemperature"))) / 100
        b.charging = (d["IsCharging"] as? Bool) ?? false
        b.plugged = (d["ExternalConnected"] as? Bool) ?? false
        b.adapterW = int("Watts", in: d["AdapterDetails"] as? [String: Any])
        b.volts = Double(int("Voltage")) / 1000
        let mA = Double((d["Amperage"] as? NSNumber)?.int64Value ?? 0)
        b.flowW = b.volts * mA / 1000
        s.battery = b

        if let t = d["PowerTelemetryData"] as? [String: Any] {
            let load = int("SystemLoad", in: t), pin = int("SystemPowerIn", in: t)
            if load > 0 { s.systemW = Double(load) / 1000 }
            s.adapterW = b.plugged ? Double(pin) / 1000 : 0
        }
    }

    private func readIOReport(_ s: inout MetricsSnapshot) {
        guard let (channels, dt) = sampler?.sample() else { return }
        var cores: [CoreStat] = []
        var eSum = 0.0, eRes = 0.0, pSum = 0.0, pRes = 0.0
        var eIdx = 0, pIdx = 0
        for c in channels {
            if c.group == "Energy Model" {
                let scale: Double = switch c.unit { case "mJ": 1e-3; case "uJ": 1e-6; case "nJ": 1e-9; default: 0 }
                let w = Double(c.value) * scale / dt
                if c.name == "GPU Energy" { s.gpuW = w }
                if c.name == "CPU Energy", w > 0 { s.cpuW = w }
            } else if c.subgroup == "CPU Core Performance States", c.name.contains("CPU") {
                let isP = !c.name.hasPrefix("E")
                let table = isP ? pTable : eTable
                var idle = 0.0, active = 0.0, weighted = 0.0, step = 0
                for st in c.states {
                    let r = Double(st.residency)
                    if st.name == "IDLE" || st.name == "OFF" || st.name == "DOWN" { idle += r; continue }
                    active += r
                    if step < table.count { weighted += r * table[step] }
                    step += 1
                }
                let total = idle + active
                let mhz = active > 0 ? weighted / active : 0
                if isP { pIdx += 1; pSum += weighted; pRes += active } else { eIdx += 1; eSum += weighted; eRes += active }
                let prefix = String((isP ? pName : eName).prefix(1))
                cores.append(CoreStat(id: cores.count, label: "\(prefix)\(isP ? pIdx : eIdx)", isPerformance: isP,
                                      usage: total > 0 ? active / total : 0, mhz: mhz))
            } else if c.subgroup == "GPU Performance States", c.name == "GPUPH" {
                var off = 0.0, on = 0.0
                for st in c.states { if st.name == "OFF" || st.name == "IDLE" { off += Double(st.residency) } else { on += Double(st.residency) } }
                if off + on > 0 { s.gpuUsage = on / (off + on) }
            }
        }
        s.cores = cores
        s.eMHz = eRes > 0 ? eSum / eRes : 0
        s.pMHz = pRes > 0 ? pSum / pRes : 0
    }
}

@MainActor @Observable
final class SystemMonitor {
    var snap = MetricsSnapshot()
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memHistory: [Double] = []
    var powerHistory: [Double] = []
    var tempHistory: [Double] = []
    var netHistory: [Double] = []
    var peakW = 0.0

    @ObservationIgnored let engine = MetricsEngine()
    @ObservationIgnored private let queue = DispatchQueue(label: "cleansilicon.metrics", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?

    init() { start() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        let engine = engine
        t.setEventHandler { [weak self] in
            let s = engine.read()
            DispatchQueue.main.async { self?.push(s) }
        }
        t.resume()
        timer = t
    }

    private func push(_ s: MetricsSnapshot) {
        func add(_ a: inout [Double], _ v: Double) { a.append(v); if a.count > 60 { a.removeFirst(a.count - 60) } }
        withAnimation(.smooth(duration: 0.6)) {
            snap = s
            add(&cpuHistory, s.cpuTotal)
            add(&gpuHistory, s.gpuUsage)
            add(&memHistory, s.memFraction)
            if let t = s.cpuTemp { add(&tempHistory, t) }
            add(&netHistory, s.netDown)
            if let w = s.systemW ?? s.gpuW { add(&powerHistory, w); peakW = max(peakW, w) }
        }
    }
}
