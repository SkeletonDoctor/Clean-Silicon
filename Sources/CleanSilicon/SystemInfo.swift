import Foundation
import Observation

struct SpecRow: Identifiable { let id = UUID(); let label: String; let value: String }
struct SpecSection: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var rows: [SpecRow]
}

enum SpecsLoader {
    static func profiler() -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["-json", "SPHardwareDataType", "SPDisplaysDataType", "SPStorageDataType", "SPSoftwareDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func ghz(_ mhz: Double) -> String { String(format: "%.2f GHz", mhz / 1000) }

    static func load(engine: MetricsEngine) -> (name: String, chip: String, sections: [SpecSection]) {
        let j = profiler()
        func first(_ k: String) -> [String: Any] { (j[k] as? [[String: Any]])?.first ?? [:] }
        func str(_ d: [String: Any], _ k: String) -> String? { d[k] as? String }
        let hw = first("SPHardwareDataType"), sw = first("SPSoftwareDataType"), gpu = first("SPDisplaysDataType")

        let chip = str(hw, "chip_type") ?? sysctlString("machdep.cpu.brand_string")
        let name = str(hw, "machine_name") ?? "Mac"
        let pCores = sysctlInt("hw.perflevel0.physicalcpu"), eCores = sysctlInt("hw.perflevel1.physicalcpu")
        let mem = ProcessInfo.processInfo.physicalMemory

        var rows: [(String, String?)] = [
            ("Model", name), ("Identifier", str(hw, "machine_model") ?? sysctlString("hw.model")),
            ("Model number", str(hw, "model_number")), ("Serial number", str(hw, "serial_number")),
            ("Firmware", str(hw, "boot_rom_version")),
        ]
        var sections = [SpecSection(title: "Machine", symbol: "laptopcomputer", rows: clean(rows))]

        rows = [("Chip", chip), ("Total cores", "\(sysctlInt("hw.physicalcpu"))"),
                ("\(engine.pName) cores", pCores > 0 ? "\(pCores)" : nil),
                ("\(engine.eName) cores", eCores > 0 ? "\(eCores)" : nil),
                ("\(engine.pName) max speed", engine.pTable.max().map(ghz)),
                ("\(engine.eName) max speed", engine.eTable.max().map(ghz)),
                ("Architecture", "arm64"),
                ("L2 cache", sysctlInt("hw.perflevel0.l2cachesize") > 0 ? Int64(sysctlInt("hw.perflevel0.l2cachesize")).formatted(.byteCount(style: .memory)) : nil)]
        sections.append(SpecSection(title: "Processor", symbol: "cpu", rows: clean(rows)))

        rows = [("Unified memory", Int64(mem).formatted(.byteCount(style: .memory))),
                ("Page size", "\(vm_kernel_page_size / 1024) KB")]
        sections.append(SpecSection(title: "Memory", symbol: "memorychip", rows: clean(rows)))

        rows = [("GPU", str(gpu, "sppci_model")), ("GPU cores", str(gpu, "sppci_cores")),
                ("Metal", str(gpu, "spdisplays_mtlgpufamilysupport")?.replacingOccurrences(of: "spdisplays_", with: "").capitalized)]
        for d in (gpu["spdisplays_ndrvs"] as? [[String: Any]]) ?? [] {
            let res = str(d, "_spdisplays_pixels") ?? str(d, "_spdisplays_resolution")
            rows.append((str(d, "_name") ?? "Display", res))
        }
        sections.append(SpecSection(title: "Graphics & Displays", symbol: "display", rows: clean(rows)))

        let vols = (j["SPStorageDataType"] as? [[String: Any]]) ?? []
        if let root = vols.first(where: { str($0, "mount_point") == "/" }) ?? vols.first {
            let drive = root["physical_drive"] as? [String: Any] ?? [:]
            rows = [("Drive", str(drive, "device_name")), ("Type", str(drive, "medium_type")?.uppercased()),
                    ("Protocol", str(drive, "protocol")), ("File system", str(root, "file_system")),
                    ("Capacity", (root["size_in_bytes"] as? NSNumber).map { $0.int64Value.formatted(.byteCount(style: .file)) }),
                    ("S.M.A.R.T.", str(drive, "smart_status"))]
            sections.append(SpecSection(title: "Storage", symbol: "internaldrive", rows: clean(rows)))
        }

        rows = [("System", str(sw, "os_version")), ("Kernel", str(sw, "kernel_version")),
                ("Computer name", str(sw, "local_host_name")), ("User", str(sw, "user_name")),
                ("System Integrity Protection", str(sw, "system_integrity")?.replacingOccurrences(of: "integrity_", with: "").capitalized),
                ("Secure virtual memory", str(sw, "secure_vm")?.replacingOccurrences(of: "secure_vm_", with: "").capitalized)]
        sections.append(SpecSection(title: "Software", symbol: "apple.logo", rows: clean(rows)))
        return (name, chip, sections)
    }

    private static func clean(_ rows: [(String, String?)]) -> [SpecRow] {
        rows.compactMap { r in r.1.flatMap { $0.isEmpty ? nil : SpecRow(label: r.0, value: $0) } }
    }
}

@MainActor @Observable
final class SpecsModel {
    var machineName = "Mac"
    var chip = sysctlString("machdep.cpu.brand_string")
    var sections: [SpecSection] = []
    var loaded = false

    func load(engine: MetricsEngine) {
        guard !loaded else { return }
        loaded = true
        Task {
            let r = await Task.detached { SpecsLoader.load(engine: engine) }.value
            machineName = r.name; chip = r.chip; sections = r.sections
        }
    }
}
