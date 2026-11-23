import Foundation
import AppKit
import Observation
import SwiftUI

struct AppEntry: Identifiable {
    let url: URL
    let name: String
    let bundleID: String
    var size: Int64
    var lastUsed: Date?
    var leftovers: [CleanItem]?
    var id: String { url.path }
    var leftoverSize: Int64 { (leftovers ?? []).reduce(0) { $0 + ($1.selected ? $1.size : 0) } }
}

enum AppScanner {
    static func installed() -> [AppEntry] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), Disk.home.appendingPathComponent("Applications")]
        let urls = roots.flatMap(Disk.children).filter { $0.pathExtension == "app" }
        var entries: [AppEntry] = urls.compactMap { u in
            guard let id = Bundle(url: u)?.bundleIdentifier, !id.hasPrefix("com.apple."), id != "com.cleansilicon.app" else { return nil }
            let used = NSMetadataItem(url: u)?.value(forAttribute: kMDItemLastUsedDate as String) as? Date
            return AppEntry(url: u, name: u.deletingPathExtension().lastPathComponent, bundleID: id, size: 0, lastUsed: used)
        }
        var sizes = [Int64](repeating: 0, count: entries.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: entries.count) { i in base[i] = Disk.treeSize(entries[i].url) }
        }
        for i in entries.indices { entries[i].size = sizes[i] }
        return entries.sorted { $0.size > $1.size }
    }

    /// Support files an app leaves in the user Library. Matches the bundle identifier exactly
    /// (or as a dotted prefix), and the app's own name only in folders where that is the convention.
    static func leftovers(name: String, bundleID: String) -> [CleanItem] {
        guard bundleID.split(separator: ".").count >= 2 else { return [] }
        let lib = Disk.home.appendingPathComponent("Library")
        let byName: Set<String> = ["Application Support", "Caches", "Logs"]
        let folders = ["Application Support", "Caches", "Logs", "Preferences", "Containers", "Group Containers", "Saved Application State",
                       "HTTPStorages", "WebKit", "Cookies", "Application Scripts", "LaunchAgents"]
        var found: [URL] = []
        for f in folders {
            for u in Disk.children(lib.appendingPathComponent(f)) {
                let n = u.lastPathComponent
                let idMatch = n == bundleID || n.hasPrefix(bundleID + ".") || n.hasSuffix("." + bundleID)
                if idMatch || (byName.contains(f) && n == name) { found.append(u) }
            }
        }
        return found.map { CleanItem(url: $0, name: $0.lastPathComponent, detail: CleanerScanner.shortPath($0.deletingLastPathComponent()), size: Disk.treeSize($0), selected: true) }
            .sorted { $0.size > $1.size }
    }
}

@MainActor @Observable
final class AppsModel {
    var apps: [AppEntry] = []
    var loading = false
    var loaded = false
    var query = ""
    var expanded: String?
    var message: String?

    var filtered: [AppEntry] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }
    var total: Int64 { apps.reduce(0) { $0 + $1.size } }

    func load(force: Bool = false) async {
        guard !loading, force || !loaded else { return }
        loading = true
        let list = await Task.detached(priority: .userInitiated) { AppScanner.installed() }.value
        withAnimation(.spring(duration: 0.5)) { apps = list; loading = false; loaded = true; expanded = nil }
    }

    func toggle(_ app: AppEntry) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { expanded = expanded == app.id ? nil : app.id }
        guard expanded == app.id, app.leftovers == nil else { return }
        Task {
            let items = await Task.detached { AppScanner.leftovers(name: app.name, bundleID: app.bundleID) }.value
            if let i = apps.firstIndex(where: { $0.id == app.id }) { withAnimation(.spring) { apps[i].leftovers = items } }
        }
    }

    func toggleLeftover(_ itemID: String, in appID: String) {
        guard let i = apps.firstIndex(where: { $0.id == appID }), let j = apps[i].leftovers?.firstIndex(where: { $0.id == itemID }) else { return }
        apps[i].leftovers?[j].selected.toggle()
    }

    func isRunning(_ app: AppEntry) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty }

    /// Moves the app and its ticked support files to the Trash.
    func uninstall(_ app: AppEntry) {
        guard let current = apps.first(where: { $0.id == app.id }) else { return }
        let fm = FileManager.default
        guard (try? fm.trashItem(at: current.url, resultingItemURL: nil)) != nil else {
            withAnimation { message = "macOS would not let \(current.name) be moved. It may be protected or need an administrator; drag it to the Trash in Finder instead." }
            return
        }
        var moved = current.size, failed = 0
        for item in current.leftovers ?? [] where item.selected {
            if (try? fm.trashItem(at: item.url, resultingItemURL: nil)) != nil { moved += item.size } else { failed += 1 }
        }
        withAnimation(.spring(duration: 0.5)) {
            apps.removeAll { $0.id == app.id }
            expanded = nil
            message = "\(current.name) and its files (\(bytes(moved))) moved to the Trash." + (failed > 0 ? " \(failed) protected item\(failed == 1 ? "" : "s") stayed in place." : "")
        }
    }
}
