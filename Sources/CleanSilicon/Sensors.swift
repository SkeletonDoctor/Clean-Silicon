import Foundation
import IOKit

/// Reads the temperature sensors built into Apple silicon through the HID event system.
final class TemperatureSensors {
    struct Reading { var cpu: Double?; var cpuMax: Double?; var battery: Double?; var ssd: Double? }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias MatchFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias ServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias PropFn = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias EventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatFn = @convention(c) (AnyObject, Int32) -> Double

    private let copyEvent: EventFn
    private let floatValue: FloatFn
    private let client: AnyObject
    private var sensors: [(name: String, service: AnyObject)] = []

    init?() {
        let h = dlopen(nil, RTLD_NOW)
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let match = sym("IOHIDEventSystemClientSetMatching", MatchFn.self),
              let services = sym("IOHIDEventSystemClientCopyServices", ServicesFn.self),
              let prop = sym("IOHIDServiceClientCopyProperty", PropFn.self),
              let event = sym("IOHIDServiceClientCopyEvent", EventFn.self),
              let fval = sym("IOHIDEventGetFloatValue", FloatFn.self),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        copyEvent = event; floatValue = fval; client = c
        _ = match(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        for s in (services(c)?.takeRetainedValue() as [AnyObject]?) ?? [] {
            if let name = prop(s, "Product" as CFString)?.takeRetainedValue() as? String { sensors.append((name, s)) }
        }
        if sensors.isEmpty { return nil }
    }

    func read() -> Reading {
        var die: [Double] = [], batt: [Double] = [], nand: [Double] = []
        for s in sensors {
            let isDie = s.name.hasPrefix("PMU tdie") || s.name.contains("MTR Temp") || s.name.contains("SOC MTR")
            let isBatt = s.name.contains("battery"), isNand = s.name.hasPrefix("NAND")
            guard isDie || isBatt || isNand, let e = copyEvent(s.service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = floatValue(e, 15 << 16)
            guard v > 0, v < 130 else { continue }
            if isDie { die.append(v) } else if isBatt { batt.append(v) } else { nand.append(v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return Reading(cpu: avg(die), cpuMax: die.max(), battery: avg(batt), ssd: avg(nand))
    }
}

struct ProcStat: Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double      // percent of one core
    let memory: Int64    // bytes
    var id: Int32 { pid }
}

enum SystemProbe {
    /// Total bytes received and sent on physical network interfaces since boot.
    static func networkBytes() -> (down: UInt64, up: UInt64) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return (0, 0) }
        defer { freeifaddrs(list) }
        var down: UInt64 = 0, up: UInt64 = 0
        var p = list
        while let c = p {
            if let a = c.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), let d = c.pointee.ifa_data {
                let name = String(cString: c.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    let data = d.assumingMemoryBound(to: if_data.self).pointee
                    down += UInt64(data.ifi_ibytes); up += UInt64(data.ifi_obytes)
                }
            }
            p = c.pointee.ifa_next
        }
        return (down, up)
    }

    static func processes() -> (cpu: [ProcStat], memory: [ProcStat]) {
        let out = Disk.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="])
        var all: [ProcStat] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { continue }
            all.append(ProcStat(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024))
        }
        return (Array(all.sorted { $0.cpu > $1.cpu }.prefix(7)), Array(all.sorted { $0.memory > $1.memory }.prefix(7)))
    }
}
