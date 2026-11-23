import Foundation
import CryptoKit
import Observation
import SwiftUI

struct ScanOptions {
    var largeMB = 500
    var downloadDays = 90
}

extension CleanerScanner {
    static func simulators() -> [CleanItem] {
        let root = lib.appendingPathComponent("Developer/CoreSimulator/Devices")
        return Disk.children(root).compactMap { dir -> CleanItem? in
            guard let plist = NSDictionary(contentsOf: dir.appendingPathComponent("device.plist")), let name = plist["name"] as? String else { return nil }
            let runtime = ((plist["runtime"] as? String) ?? "").split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? ""
            let size = Disk.treeSize(dir)
            guard size > 1_000_000 else { return nil }
            return CleanItem(url: dir, name: name, detail: "Simulator · \(runtime)", size: size, selected: false)
        }
        .sorted { $0.size > $1.size }
    }

    static func walk(_ roots: [URL], _ body: (URL, URLResourceValues) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey]
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                body(u, v)
            }
        }
    }

    static func installers() -> [CleanItem] {
        let exts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "ipsw"]
        var out: [CleanItem] = []
        walk(["Downloads", "Desktop", "Documents"].map(Disk.home.appendingPathComponent)) { u, v in
            guard exts.contains(u.pathExtension.lowercased()), let size = v.totalFileAllocatedSize, size > 0 else { return }
            out.append(CleanItem(url: u, name: u.lastPathComponent, detail: shortPath(u.deletingLastPathComponent()), size: Int64(size), selected: false))
        }
        return out.sorted { $0.size > $1.size }
    }

    static func screenshots() -> [CleanItem] {
        var folders = [Disk.home.appendingPathComponent("Desktop")]
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            folders.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var seen = Set<String>(), out: [CleanItem] = []
        for f in folders {
            for u in Disk.children(f) where seen.insert(u.path).inserted {
                let n = u.lastPathComponent
                guard n.hasPrefix("Screenshot") || n.hasPrefix("Screen Recording") || n.hasPrefix("Screen Shot"),
                      let v = try? u.resourceValues(forKeys: [.creationDateKey, .totalFileAllocatedSizeKey]),
                      (v.creationDate ?? Date()) < cutoff else { continue }
                out.append(CleanItem(url: u, name: n, detail: shortPath(f), size: Int64(v.totalFileAllocatedSize ?? 0), selected: false))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Fingerprint of a file: full hash for small files, head + tail + length for very large ones.
    static func fingerprint(_ url: URL, size: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        let chunk = 4 << 20
        if size <= 256 << 20 {
            while let d = try? h.read(upToCount: chunk), !d.isEmpty { sha.update(data: d) }
        } else {
            guard let head = try? h.read(upToCount: chunk) else { return nil }
            sha.update(data: head)
            try? h.seek(toOffset: UInt64(size - chunk))
            if let tail = try? h.read(upToCount: chunk) { sha.update(data: tail) }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined() + ":\(size)"
    }

    /// Identical copies of files (1 MB and up) in the main user folders. The oldest copy is kept off the list.
    static func duplicates() -> [CleanItem] {
        var bySize: [Int: [(URL, Date, Int64)]] = [:]
        walk(["Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures"].map(Disk.home.appendingPathComponent)) { u, v in
            guard let alloc = v.totalFileAllocatedSize, alloc >= 1_000_000,
                  let length = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
            bySize[length, default: []].append((u, v.creationDate ?? .distantPast, Int64(alloc)))
        }
        var out: [CleanItem] = []
        for (length, group) in bySize where group.count > 1 {
            var byHash: [String: [(URL, Date, Int64)]] = [:]
            for g in group { if let f = fingerprint(g.0, size: length) { byHash[f, default: []].append(g) } }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted { $0.1 < $1.1 }
                for copy in sorted.dropFirst() {
                    out.append(CleanItem(url: copy.0, name: copy.0.lastPathComponent, detail: "Copy of \(shortPath(sorted[0].0))", size: copy.2, selected: false))
                }
            }
        }
        return Array(out.sorted { $0.size > $1.size }.prefix(300))
    }
}

// MARK: - One-click maintenance tools

struct MaintenanceTool: Identifiable {
    enum State { case idle, running, done, failed }
    let id: String
    let title: String
    let blurb: String
    let symbol: String
    let tint: Color
    let admin: Bool
    let command: String
    var state: State = .idle
}

@MainActor @Observable
final class MaintenanceModel {
    var tools: [MaintenanceTool] = {
        var t: [MaintenanceTool] = [
            .init(id: "ram", title: "Free Up Memory", blurb: "Purge inactive memory and disk caches", symbol: "memorychip.fill", tint: Palette.violet, admin: true, command: "/usr/sbin/purge"),
            .init(id: "dns", title: "Flush DNS Cache", blurb: "Fixes sites that will not load after network changes", symbol: "network", tint: Palette.sky, admin: true,
                  command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
            .init(id: "ql", title: "Reset Quick Look Cache", blurb: "Clears stored file previews and thumbnails", symbol: "eye.fill", tint: Palette.mint, admin: false, command: "/usr/bin/qlmanage -r cache"),
        ]
        if FileManager.default.fileExists(atPath: "/usr/bin/xcrun") {
            t.append(.init(id: "sim", title: "Remove Dead Simulators", blurb: "Deletes simulators whose iOS runtime is no longer installed", symbol: "iphone.slash", tint: Palette.orange, admin: false,
                           command: "/usr/bin/xcrun simctl delete unavailable"))
        }
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.fileExists(atPath:)) {
            t.append(.init(id: "brew", title: "Homebrew Cleanup", blurb: "Removes old package versions and downloads", symbol: "mug.fill", tint: Palette.pink, admin: false,
                           command: "\(brew) cleanup -s --prune=all"))
        }
        return t
    }()

    func run(_ id: String) async {
        guard let i = tools.firstIndex(where: { $0.id == id }), tools[i].state != .running else { return }
        let tool = tools[i]
        withAnimation(.snappy) { tools[i].state = .running }
        let ok = await Task.detached { () -> Bool in
            let p = Process()
            if tool.admin {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"\(tool.command)\" with administrator privileges"]
            } else {
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", tool.command]
            }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
        withAnimation(.spring(duration: 0.4, bounce: 0.4)) { tools[i].state = ok ? .done : .failed }
        try? await Task.sleep(for: .seconds(4))
        withAnimation(.easeOut) { tools[i].state = .idle }
    }
}

struct MaintenanceCard: View {
    @Environment(MaintenanceModel.self) private var model
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick tools").font(.system(size: 15, weight: .semibold, design: .rounded))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(model.tools) { t in ToolButton(tool: t) }
            }
        }
        .padding(18)
        .glassCard()
    }
}

struct ToolButton: View {
    @Environment(MaintenanceModel.self) private var model
    let tool: MaintenanceTool
    @State private var hover = false
    var body: some View {
        Button { Task { await model.run(tool.id) } } label: {
            HStack(spacing: 11) {
                ZStack {
                    IconTile(symbol: tool.symbol, tint: tool.tint, size: 36).opacity(tool.state == .idle ? 1 : 0.25)
                    switch tool.state {
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.mint).transition(.scale)
                    case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.pink).transition(.scale)
                    case .idle: EmptyView()
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(tool.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                        if tool.admin { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).help("Asks for your password") }
                    }
                    Text(tool.state == .done ? "Done" : (tool.state == .failed ? "Did not finish" : tool.blurb))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(.white.opacity(hover ? 0.11 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(hover ? 0.2 : 0.08), lineWidth: 0.8))
            .scaleEffect(hover ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
    }
}

struct OptionChips: View {
    let title: String
    let options: [(String, Int)]
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 2) {
                ForEach(options, id: \.1) { o in
                    Button { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { value = o.1 } } label: {
                        Text(o.0).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(value == o.1 ? AnyShapeStyle(Palette.sky.opacity(0.55)) : AnyShapeStyle(.clear), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.07), in: Capsule())
        }
    }
}

struct FanStrip: View {
    @Environment(SystemMonitor.self) private var monitor
    var body: some View {
        let fans = monitor.snap.fans
        HStack(spacing: 16) {
            IconTile(symbol: "fan.fill", tint: Palette.sky, size: 36)
            if let fans, !fans.isEmpty {
                ForEach(fans) { f in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "fan.fill").font(.system(size: 12)).foregroundStyle(Palette.sky)
                                .symbolEffect(.rotate, options: .repeat(.continuous).speed(max(0.2, f.rpm / 1500)), isActive: f.rpm > 50)
                            Text(fans.count > 1 ? "Fan \(f.id + 1)" : "Fan").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                            Text("\(Int(f.rpm)) rpm").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                        }
                        DistributionBar(parts: [(Palette.sky, Int64(max(0, f.rpm - f.minRPM))), (.white.opacity(0.12), Int64(max(1, f.maxRPM - f.rpm)))], height: 6)
                        Text("\(Int(f.minRPM))–\(Int(f.maxRPM)) rpm range").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fans == nil ? "Fan speed unavailable" : "No fans in this Mac").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(fans == nil ? "The fan controller could not be read." : "It is cooled passively, so there is no fan speed to show. On Macs with fans, live rpm appears here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 22)
    }
}
