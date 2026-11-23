import Foundation
import AppKit
import Observation
import SwiftUI

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f
}()
func bytes(_ v: Int64) -> String { byteFormatter.string(fromByteCount: v) }

enum Disk {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// On-disk size of a file or whole folder tree. Never follows symlinks or crosses volumes.
    static func treeSize(_ url: URL, cancelled: () -> Bool = { false }) -> Int64 {
        guard let p = strdup(url.path) else { return 0 }
        defer { free(p) }
        var argv: [UnsafeMutablePointer<CChar>?] = [p, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        var total: Int64 = 0
        var n = 0
        while let e = fts_read(fts) {
            let info = Int32(e.pointee.fts_info)
            if info == FTS_F || info == FTS_D || info == FTS_SL || info == FTS_DEFAULT, let st = e.pointee.fts_statp {
                total += Int64(st.pointee.st_blocks) * 512
            }
            n += 1
            if n & 2047 == 0, cancelled() { break }
        }
        return total
    }

    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func volume() -> (total: Int64, free: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Full Disk Access shows up as being able to open the privacy database.
    static func hasFullDiskAccess() -> Bool {
        if let h = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") { try? h.close(); return true }
        // Fallback probes: folders only readable with Full Disk Access.
        let probes = ["Library/Application Support/com.apple.TCC", "Library/Safari", "Library/Mail"]
        return probes.contains { (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent($0).path)) != nil }
    }

    static func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }

    /// Starts a fresh copy of the app and quits this one (macOS applies new privacy grants on launch).
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func localSnapshots() -> [String] {
        run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"]).split(separator: "\n").map(String.init)
            .filter { $0.first?.isNumber == true }
    }
}

// MARK: - Cleaner

struct CleanItem: Identifiable {
    let url: URL
    var name: String
    var detail: String
    var size: Int64
    var selected: Bool
    var id: String { url.path }
}

enum CleanMode { case delete, trash }
enum ScanState { case idle, waiting, scanning, done }

struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let symbol: String
    let tint: Color
    let mode: CleanMode
    let recommended: Bool
    var items: [CleanItem] = []
    var state: ScanState = .idle
    var expanded = false

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.reduce(0) { $0 + ($1.selected ? $1.size : 0) } }
    var selectedCount: Int { items.filter(\.selected).count }
}

enum CleanerScanner {
    static let fm = FileManager.default
    static var lib: URL { Disk.home.appendingPathComponent("Library") }

    static func existing(_ paths: [String]) -> [URL] {
        paths.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : Disk.home.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    static func candidates(_ id: String, options: ScanOptions = ScanOptions()) -> [URL] {
        switch id {
        case "mail":
            return Disk.children(lib.appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads"))
        case "caches":
            return Disk.children(lib.appendingPathComponent("Caches")).filter { $0.lastPathComponent != "com.cleansilicon.app" }
        case "logs":
            return Disk.children(lib.appendingPathComponent("Logs"))
                + Disk.children(URL(fileURLWithPath: "/Library/Logs")).filter { fm.isDeletableFile(atPath: $0.path) }
        case "xcode":
            let dev = lib.appendingPathComponent("Developer")
            return ["Xcode/DerivedData", "Xcode/iOS DeviceSupport", "Xcode/watchOS DeviceSupport", "Xcode/tvOS DeviceSupport",
                    "Xcode/Archives", "CoreSimulator/Caches"].flatMap { Disk.children(dev.appendingPathComponent($0)) }
                + existing(["Library/Developer/Xcode/UserData/Previews", "Library/Developer/Xcode/DocumentationCache"])
        case "dev":
            // ~/.cache is listed folder by folder: it can hold downloaded AI models next to real caches.
            return Disk.children(Disk.home.appendingPathComponent(".cache")) + existing([".npm/_cacache", ".gradle/caches", ".cargo/registry/cache", ".pnpm-store", "Library/pnpm/store",
                             ".bun/install/cache", ".yarn/cache", ".cocoapods/repos", ".nuget/packages", ".m2/repository",
                             "go/pkg/mod/cache", ".wrangler/logs", ".docker/buildx/cache"])
        case "system":
            var out = Disk.children(URL(fileURLWithPath: "/Library/Caches")).filter { fm.isDeletableFile(atPath: $0.path) }
            // Per-user cache folder inside /private/var/folders, a big part of "System Data".
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
            out += Disk.children(tmp.appendingPathComponent("C")).filter { !$0.lastPathComponent.hasPrefix("com.apple.") }
            return out
        case "ios":
            return Disk.children(lib.appendingPathComponent("Application Support/MobileSync/Backup"))
                + Disk.children(lib.appendingPathComponent("iTunes/iPhone Software Updates"))
                + Disk.children(lib.appendingPathComponent("iTunes/iPad Software Updates"))
        case "trash":
            return Disk.children(Disk.home.appendingPathComponent(".Trash"))
        case "downloads":
            let cutoff = Date().addingTimeInterval(-Double(options.downloadDays) * 86400)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .addedToDirectoryDateKey]
            return Disk.children(Disk.home.appendingPathComponent("Downloads")).filter { u in
                guard !u.lastPathComponent.hasPrefix("."), let v = try? u.resourceValues(forKeys: keys) else { return false }
                let newest = max(v.contentModificationDate ?? .distantPast, v.addedToDirectoryDate ?? .distantPast)
                return newest < cutoff
            }
        default:
            return []
        }
    }

    /// Files of 500 MB or more in the home folder (outside Library and the Trash).
    static func largeFiles(minimum: Int64 = 500_000_000) -> [CleanItem] {
        guard let p = strdup(Disk.home.path) else { return [] }
        defer { free(p) }
        var argv: [UnsafeMutablePointer<CChar>?] = [p, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return [] }
        defer { fts_close(fts) }
        var out: [CleanItem] = []
        while let e = fts_read(fts) {
            let info = Int32(e.pointee.fts_info)
            if info == FTS_D, e.pointee.fts_level == 1 {
                let name = String(cString: e.pointee.fts_path).split(separator: "/").last.map(String.init) ?? ""
                if name == "Library" || name == ".Trash" { fts_set(fts, e, FTS_SKIP) }
            } else if info == FTS_F, let st = e.pointee.fts_statp {
                let size = Int64(st.pointee.st_blocks) * 512
                if size >= minimum {
                    let url = URL(fileURLWithPath: String(cString: e.pointee.fts_path))
                    out.append(CleanItem(url: url, name: url.lastPathComponent, detail: shortPath(url.deletingLastPathComponent()), size: size, selected: false))
                }
            }
        }
        return Array(out.sorted { $0.size > $1.size }.prefix(60))
    }

    static func shortPath(_ url: URL) -> String {
        let p = url.path, h = Disk.home.path
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    /// Downloaded models and datasets live in cache folders but are slow or costly to fetch again.
    static let keepByDefault: Set<String> = ["huggingface", "torch", "lm-studio", "ollama", "whisper", "modelscope", "mlx", "archives"]

    static func scan(_ id: String, preselect: Bool, options: ScanOptions = ScanOptions()) -> [CleanItem] {
        switch id {
        case "large": return largeFiles(minimum: Int64(options.largeMB) * 1_000_000)
        case "simulators": return simulators()
        case "installers": return installers()
        case "screenshots": return screenshots()
        case "duplicates": return duplicates()
        default: break
        }
        let urls = candidates(id, options: options)
        var sizes = [Int64](repeating: 0, count: urls.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in base[i] = Disk.treeSize(urls[i]) }
        }
        return zip(urls, sizes).filter { $0.1 >= 16 * 1024 }
            .map { CleanItem(url: $0.0, name: $0.0.lastPathComponent, detail: shortPath($0.0.deletingLastPathComponent()), size: $0.1,
                             selected: preselect && !keepByDefault.contains($0.0.lastPathComponent.lowercased()) && !$0.0.path.contains("/Xcode/Archives/")) }
            .sorted { $0.size > $1.size }
    }

    /// Removes one item. Returns the bytes that are still on disk afterwards (0 = fully removed).
    static func remove(_ item: CleanItem, mode: CleanMode) -> Int64 {
        let path = item.url.path
        if mode == .trash {
            return (try? fm.trashItem(at: item.url, resultingItemURL: nil)) != nil ? 0 : item.size
        }
        if path.contains("/CoreSimulator/Devices/") {
            // Let Xcode's own tool unregister the simulator instead of pulling its folder out from under it.
            _ = Disk.run("/usr/bin/xcrun", ["simctl", "delete", item.url.lastPathComponent])
            return fm.fileExists(atPath: path) ? item.size : 0
        }
        if (try? fm.removeItem(at: item.url)) != nil { return 0 }
        // Protected folder: clear whatever inside it can be cleared.
        for child in Disk.children(item.url) { try? fm.removeItem(at: child) }
        return fm.fileExists(atPath: path) ? Disk.treeSize(item.url) : 0
    }
}

struct CleanResult { var freed: Int64; var trashed: Int64; var skipped: Int }

@MainActor @Observable
final class CleanerModel {
    var categories: [CleanCategory] = [
        .init(id: "caches", title: "App Caches", blurb: "Temporary files apps rebuild on their own", symbol: "shippingbox.fill", tint: Palette.sky, mode: .delete, recommended: true),
        .init(id: "logs", title: "Logs & Crash Reports", blurb: "Diagnostic logs and old crash reports", symbol: "doc.text.fill", tint: Palette.mint, mode: .delete, recommended: true),
        .init(id: "xcode", title: "Xcode Junk", blurb: "Derived data, device support, simulator caches, archives", symbol: "hammer.fill", tint: Palette.violet, mode: .delete, recommended: true),
        .init(id: "dev", title: "Developer Caches", blurb: "npm, Gradle, Cargo, CocoaPods and other package caches", symbol: "terminal.fill", tint: Palette.orange, mode: .delete, recommended: true),
        .init(id: "mail", title: "Mail Attachments", blurb: "Attachments Mail saved when you opened them; still in your mailbox", symbol: "paperclip", tint: Palette.sky, mode: .delete, recommended: true),
        .init(id: "trash", title: "Trash", blurb: "Items waiting in the Trash", symbol: "trash.fill", tint: Palette.pink, mode: .delete, recommended: true),
        .init(id: "system", title: "System Caches", blurb: "Shared caches and hidden per-user cache folders", symbol: "gearshape.2.fill", tint: Palette.sky, mode: .delete, recommended: false),
        .init(id: "ios", title: "iOS Backups & Firmware", blurb: "Local device backups and downloaded updates", symbol: "iphone", tint: Palette.mint, mode: .trash, recommended: false),
        .init(id: "downloads", title: "Old Downloads", blurb: "Untouched in Downloads for over 90 days", symbol: "arrow.down.circle.fill", tint: Palette.orange, mode: .trash, recommended: false),
        .init(id: "simulators", title: "iOS Simulators", blurb: "Simulator devices with their installed apps and data", symbol: "ipad.and.iphone", tint: Palette.violet, mode: .delete, recommended: false),
        .init(id: "installers", title: "Installers & Disk Images", blurb: "DMG, PKG, ISO and firmware files in Downloads, Desktop and Documents", symbol: "opticaldiscdrive.fill", tint: Palette.pink, mode: .trash, recommended: false),
        .init(id: "screenshots", title: "Old Screenshots", blurb: "Screenshots and screen recordings older than 30 days", symbol: "camera.viewfinder", tint: Palette.sky, mode: .trash, recommended: false),
        .init(id: "duplicates", title: "Duplicate Files", blurb: "Identical copies in your main folders; the oldest copy is kept", symbol: "doc.on.doc.fill", tint: Palette.mint, mode: .trash, recommended: false),
        .init(id: "large", title: "Large Files", blurb: "Big files in your home folder", symbol: "doc.zipper", tint: Palette.violet, mode: .trash, recommended: false),
    ]
    var busy = false
    var scanned = false
    var cleaning = false
    var result: CleanResult?
    var snapshots: [String] = []
    var snapshotBusy = false
    var options = ScanOptions()

    var totalFound: Int64 { categories.reduce(0) { $0 + $1.total } }
    var totalSelected: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var progress: Double {
        Double(categories.filter { $0.state == .done }.count) / Double(categories.count)
    }
    var scanningTitle: String { categories.first { $0.state == .scanning }?.title ?? "" }

    func scan() async {
        guard !busy else { return }
        busy = true; result = nil
        withAnimation(.snappy) {
            for i in categories.indices { categories[i].items = []; categories[i].state = .waiting; categories[i].expanded = false }
        }
        for i in categories.indices {
            withAnimation(.snappy) { categories[i].state = .scanning }
            let id = categories[i].id, pre = categories[i].recommended, opts = options
            let items = await Task.detached(priority: .userInitiated) { CleanerScanner.scan(id, preselect: pre, options: opts) }.value
            withAnimation(.spring(duration: 0.5)) { categories[i].items = items; categories[i].state = .done }
        }
        snapshots = await Task.detached { Disk.localSnapshots() }.value
        withAnimation(.spring) { scanned = true; busy = false }
    }

    func clean() async {
        guard !busy else { return }
        busy = true; cleaning = true
        let jobs: [(String, CleanItem, CleanMode)] = categories.flatMap { c in c.items.filter(\.selected).map { (c.id, $0, c.mode) } }
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([String: Int64], CleanResult) in
            var left: [String: Int64] = [:]
            var r = CleanResult(freed: 0, trashed: 0, skipped: 0)
            for (_, item, mode) in jobs {
                let remaining = CleanerScanner.remove(item, mode: mode)
                left[item.id] = remaining
                if mode == .trash { r.trashed += item.size - remaining } else { r.freed += item.size - remaining }
                if remaining > 0 { r.skipped += 1 }
            }
            return (left, r)
        }.value
        withAnimation(.spring(duration: 0.6)) {
            for i in categories.indices {
                categories[i].items = categories[i].items.compactMap { item in
                    guard let remaining = outcome.0[item.id] else { return item }
                    if remaining <= 0 { return nil }
                    var kept = item; kept.size = remaining; kept.selected = false
                    return kept
                }
            }
            result = outcome.1
            busy = false; cleaning = false
        }
    }

    func setAll(_ on: Bool, in categoryID: String) {
        guard let i = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        for j in categories[i].items.indices { categories[i].items[j].selected = on }
    }

    func deleteSnapshots() async {
        snapshotBusy = true
        _ = await Task.detached {
            Disk.run("/usr/bin/osascript", ["-e", "do shell script \"/usr/bin/tmutil deletelocalsnapshots /\" with administrator privileges"])
        }.value
        snapshots = await Task.detached { Disk.localSnapshots() }.value
        snapshotBusy = false
    }
}

// MARK: - Space Lens

struct LensEntry: Identifiable {
    let url: URL
    let isDirectory: Bool
    var size: Int64?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@MainActor @Observable
final class LensModel {
    var current: URL = Disk.home.appendingPathComponent("Library")
    var entries: [LensEntry] = []
    var loading = false
    var denied = false
    @ObservationIgnored private var cache: [String: Int64] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    static let presets: [(String, String, URL)] = [
        ("Home", "house.fill", Disk.home),
        ("User Library", "books.vertical.fill", Disk.home.appendingPathComponent("Library")),
        ("System Library", "building.columns.fill", URL(fileURLWithPath: "/Library")),
        ("Hidden System Data", "eye.slash.fill", URL(fileURLWithPath: "/private/var")),
        ("Applications", "square.grid.2x2.fill", URL(fileURLWithPath: "/Applications")),
        ("All Users", "person.2.fill", URL(fileURLWithPath: "/Users")),
    ]

    var total: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }
    var largest: Int64 { entries.compactMap(\.size).max() ?? 0 }
    var crumbs: [URL] {
        var out: [URL] = [], u = current.standardizedFileURL
        while u.path != "/" { out.insert(u, at: 0); u = u.deletingLastPathComponent() }
        return out
    }

    func open(_ url: URL) {
        task?.cancel()
        current = url
        loading = true
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let listing = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        denied = listing == nil
        let list = (listing ?? []).map { u -> LensEntry in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return LensEntry(url: u, isDirectory: (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false), size: cache[u.path])
        }
        withAnimation(.snappy) { entries = list.sorted { ($0.size ?? -1) > ($1.size ?? -1) } }
        let pending = list.filter { $0.size == nil }.map(\.url)
        task = Task { [weak self] in
            await withTaskGroup(of: (String, Int64).self) { group in
                var it = pending.makeIterator()
                var running = 0
                func add() {
                    guard let u = it.next() else { return }
                    running += 1
                    group.addTask { (u.path, Disk.treeSize(u) { Task.isCancelled }) }
                }
                for _ in 0..<6 { add() }
                while running > 0, let (path, size) = await group.next() {
                    running -= 1
                    if Task.isCancelled { break }
                    self?.finish(path, size, in: url)
                    add()
                }
                group.cancelAll()
            }
            if !Task.isCancelled { self?.loading = false }
        }
    }

    private func finish(_ path: String, _ size: Int64, in folder: URL) {
        cache[path] = size
        guard folder == current, let i = entries.firstIndex(where: { $0.id == path }) else { return }
        withAnimation(.spring(duration: 0.45)) {
            entries[i].size = size
            entries.sort { ($0.size ?? -1) > ($1.size ?? -1) }
        }
    }

    func trash(_ entry: LensEntry) {
        guard (try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)) != nil else { NSSound.beep(); return }
        // The item and every folder above it now have a different size.
        cache[entry.id] = nil
        var up = entry.url.deletingLastPathComponent().standardizedFileURL
        while up.path != "/" { cache[up.path] = nil; up = up.deletingLastPathComponent() }
        open(current)
    }

    /// Call after anything else deletes files, so the next look at a folder is measured fresh.
    func invalidate() {
        cache.removeAll()
        if !entries.isEmpty { open(current) }
    }

    func refresh() {
        for e in entries { cache[e.id] = nil }
        open(current)
    }
}

// MARK: - Shared app state

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", cleaner = "Cleaner", lens = "Space Lens", apps = "Uninstaller", monitor = "Monitor", stress = "Stress Test", specs = "Specs"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .cleaner: "wand.and.sparkles"
        case .lens: "circle.hexagongrid.fill"
        case .apps: "trash.square.fill"
        case .monitor: "waveform.path.ecg"
        case .stress: "flame.fill"
        case .specs: "cpu.fill"
        }
    }
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let message: String
    let confirm: String
    let action: () -> Void
}

@MainActor @Observable
final class AppState {
    var page: Page = UserDefaults.standard.string(forKey: "page").flatMap { a in Page.allCases.first { $0.rawValue.lowercased().hasPrefix(a.lowercased()) } } ?? .overview
    var confirm: ConfirmRequest?
    var fullDiskAccess = Disk.hasFullDiskAccess()
    var showAccess = false
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var diskUsed: Int64 { max(0, diskTotal - diskFree) }
    var diskFraction: Double { diskTotal == 0 ? 0 : Double(diskUsed) / Double(diskTotal) }

    func refresh() {
        let v = Disk.volume()
        withAnimation(.spring(duration: 0.9)) { diskTotal = v.total; diskFree = v.free }
        fullDiskAccess = Disk.hasFullDiskAccess()
    }
}
