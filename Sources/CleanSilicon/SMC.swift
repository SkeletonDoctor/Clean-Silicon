import Foundation
import IOKit

struct FanStat: Identifiable {
    let id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
}

/// Minimal reader for the System Management Controller, used for fan speeds.
final class SMC {
    private struct Param {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var pad: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0

    init?() {
        guard MemoryLayout<Param>.size == 80 else { return nil }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.size
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<Param>.size, &output, &size)
        return kr == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    /// Reads a numeric key. Understands the float and small integer encodings fans use.
    func value(_ key: String) -> Double? {
        var p = Param()
        p.key = fourCC(key); p.data8 = 9
        guard let info = call(&p), info.dataSize > 0 else { return nil }
        p = Param()
        p.key = fourCC(key); p.dataSize = info.dataSize; p.data8 = 5
        guard let out = call(&p) else { return nil }
        let raw = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
        switch info.dataType {
        case fourCC("flt "): return raw.count == 4 ? Double(raw.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) : nil
        case fourCC("ui8 "): return raw.first.map(Double.init)
        case fourCC("ui16"): return raw.count == 2 ? Double(UInt16(raw[0]) << 8 | UInt16(raw[1])) : nil
        case fourCC("fpe2"): return raw.count == 2 ? Double(UInt16(raw[0]) << 8 | UInt16(raw[1])) / 4 : nil
        default: return nil
        }
    }

    /// nil when the controller cannot be read; an empty list on fanless Macs.
    func fans() -> [FanStat]? {
        guard let n = value("FNum") else { return [] }   // no fan key at all: fanless Mac
        return (0..<Int(n)).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return FanStat(id: i, rpm: rpm, minRPM: value("F\(i)Mn") ?? 0, maxRPM: value("F\(i)Mx") ?? max(rpm, 1))
        }
    }
}
