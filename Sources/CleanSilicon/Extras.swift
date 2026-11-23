import SwiftUI
import AppKit

func rate(_ bytesPerSecond: Double) -> String { bytes(Int64(bytesPerSecond)) + "/s" }
func heatTint(_ c: Double?) -> Color {
    guard let c else { return Palette.mint }
    return c < 55 ? Palette.mint : (c < 75 ? Palette.orange : Palette.pink)
}
func degrees(_ c: Double?) -> String { c.map { String(format: "%.0f°", $0) } ?? "—" }

extension Palette {
    static let ranked: [Color] = [sky, violet, mint, orange, pink, Color(red: 0.95, green: 0.85, blue: 0.4)]
}

/// Lifts a card slightly while the pointer is over it.
struct HoverLift: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.012 : 1)
            .shadow(color: .black.opacity(hover ? 0.35 : 0.18), radius: hover ? 22 : 12, y: hover ? 10 : 5)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: hover)
            .onHover { hover = $0 }
    }
}
extension View { func hoverLift() -> some View { modifier(HoverLift()) } }

struct StatusPill: View {
    let symbol: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded)).contentTransition(.numericText())
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassEffect(Glass.regular.tint(tint.opacity(0.14)), in: .capsule)
    }
}

/// One horizontal bar split into coloured shares.
struct DistributionBar: View {
    let parts: [(color: Color, value: Int64)]
    var height: CGFloat = 10
    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.value })
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.value > 0 {
                        Capsule().fill(p.color.gradient)
                            .frame(width: max(3, (g.size.width - CGFloat(parts.count) * 2) * CGFloat(p.value) / CGFloat(total)))
                            .shadow(color: p.color.opacity(0.5), radius: 5)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

struct GlassToggle: View {
    @Binding var isOn: Bool
    var tint: Color = Palette.sky
    var body: some View {
        Button { withAnimation(.spring(duration: 0.3, bounce: 0.4)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.white.opacity(0.12)))
                Circle().fill(.white).padding(2.5).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .frame(width: 36, height: 21)
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: 240)
        .glassEffect(Glass.regular.tint(Palette.sky.opacity(focused ? 0.18 : 0)), in: .capsule)
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

// MARK: - Monitor cards

struct TemperatureCard: View {
    @Environment(SystemMonitor.self) private var monitor
    var body: some View {
        let s = monitor.snap
        let tint = heatTint(s.cpuTemp)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "thermometer.medium").foregroundStyle(tint)
                Text("Temperature").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 18) {
                ZStack {
                    Circle().trim(from: 0, to: 0.75).stroke(.white.opacity(0.09), style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(135))
                    Circle().trim(from: 0, to: 0.75 * min(1, max(0.02, ((s.cpuTemp ?? 20) - 20) / 85)))
                        .stroke(tint.gradient,
                                style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(135)).shadow(color: tint.opacity(0.6), radius: 8)
                    VStack(spacing: -2) {
                        Text(degrees(s.cpuTemp)).font(.system(size: 30, weight: .bold, design: .rounded)).contentTransition(.numericText()).monospacedDigit()
                        Text("CPU").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: 9) {
                    row("flame.fill", "Hottest core", s.cpuTempMax)
                    row("battery.75percent", "Battery", s.batteryTemp)
                    row("internaldrive.fill", "SSD", s.ssdTemp)
                }
            }
            Sparkline(values: monitor.tempHistory.map { max(0, $0 - 25) }, ceiling: 75, tint: tint).frame(height: 34)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func row(_ symbol: String, _ label: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(heatTint(value)).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 6)
            Text(value.map { String(format: "%.1f °C", $0) } ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
        }
    }
}

struct NetworkCard: View {
    @Environment(SystemMonitor.self) private var monitor
    var body: some View {
        let s = monitor.snap
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "network").foregroundStyle(Palette.sky)
                Text("Network").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 26) {
                flow("arrow.down.circle.fill", "Download", s.netDown, Palette.sky)
                flow("arrow.up.circle.fill", "Upload", s.netUp, Palette.violet)
            }
            Sparkline(values: monitor.netHistory, ceiling: nil, tint: Palette.sky).frame(maxHeight: .infinity).frame(minHeight: 60)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private func flow(_ symbol: String, _ label: String, _ v: Double, _ tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Text(rate(v)).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            }
        }
    }
}

struct ProcessCard: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppState.self) private var app
    @State private var byMemory = false
    @Namespace private var ns

    var body: some View {
        let list = byMemory ? monitor.snap.topMemory : monitor.snap.topCPU
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top processes").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                HStack(spacing: 2) {
                    seg("CPU", !byMemory) { byMemory = false }
                    seg("Memory", byMemory) { byMemory = true }
                }
                .padding(3)
                .background(.white.opacity(0.07), in: Capsule())
            }
            VStack(spacing: 3) {
                ForEach(list) { p in ProcessRow(proc: p, byMemory: byMemory, top: byMemory ? Double(list.first?.memory ?? 1) : max(100, list.first?.cpu ?? 100)) }
            }
        }
        .padding(20)
        .glassCard()
    }

    private func seg(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(duration: 0.35, bounce: 0.3)) { action() } } label: {
            Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background { if on { Capsule().fill(.white.opacity(0.18)).matchedGeometryEffect(id: "seg", in: ns) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ProcessRow: View {
    @Environment(AppState.self) private var app
    let proc: ProcStat
    let byMemory: Bool
    let top: Double
    @State private var hover = false

    var body: some View {
        let fraction = byMemory ? Double(proc.memory) / max(top, 1) : proc.cpu / max(top, 1)
        HStack(spacing: 12) {
            Text(proc.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(width: 220, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(LinearGradient(colors: byMemory ? [Palette.violet, Palette.pink] : [Palette.sky, Palette.mint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * min(1, fraction)))
                }
            }
            .frame(height: 6)
            if hover {
                Button {
                    app.confirm = ConfirmRequest(symbol: "xmark.octagon.fill", title: "Quit “\(proc.name)”?",
                        message: "The process is asked to quit. Unsaved changes in it may be lost.", confirm: "Quit") {
                        if let a = NSRunningApplication(processIdentifier: proc.pid), a.terminate() { return }
                        kill(proc.pid, SIGTERM)
                    }
                } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle(tint: Palette.pink)).help("Quit process")
            }
            Text(byMemory ? bytes(proc.memory) : String(format: "%.1f%%", proc.cpu))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(.white.opacity(hover ? 0.09 : 0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Uninstaller

struct AppsPage: View {
    @Environment(AppState.self) private var app
    @Environment(AppsModel.self) private var apps
    @Environment(LensModel.self) private var lens

    var body: some View {
        @Bindable var apps = apps
        PageScroll {
            PageHeader(title: "Uninstaller", subtitle: "Remove apps together with the support files they leave behind") {
                HStack(spacing: 10) {
                    if apps.loading { ProgressView().controlSize(.small) }
                    SearchField(text: $apps.query, prompt: "Search apps")
                    Button { Task { await apps.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(IconButtonStyle())
                }
            }
            if let m = apps.message {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Palette.sky)
                    Text(m).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button { withAnimation { apps.message = nil } } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
                }
                .padding(14).glassCard(radius: 20, tint: Palette.sky)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                StatusPill(symbol: "square.grid.2x2.fill", text: "\(apps.apps.count) apps", tint: Palette.violet)
                StatusPill(symbol: "internaldrive.fill", text: bytes(apps.total), tint: Palette.sky)
            }
            .rise(0)
            VStack(spacing: 4) {
                if apps.loading && apps.apps.isEmpty {
                    Text("Measuring your apps…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(30)
                }
                ForEach(apps.filtered.prefix(200)) { a in AppRow(entry: a, largest: apps.apps.first?.size ?? 1) }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .glassCard()
            .rise(1)
        }
        .task { await apps.load() }
    }
}

struct AppRow: View {
    @Environment(AppState.self) private var app
    @Environment(AppsModel.self) private var apps
    @Environment(LensModel.self) private var lens
    let entry: AppEntry
    let largest: Int64
    @State private var hover = false

    var body: some View {
        let open = apps.expanded == entry.id
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(entry.lastUsed.map { "Last opened " + $0.formatted(.relative(presentation: .named)) } ?? "Never opened, or unknown")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: 230, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.06))
                        Capsule().fill(LinearGradient(colors: [Palette.violet, Palette.pink], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, g.size.width * Double(entry.size) / Double(max(largest, 1))))
                    }
                }
                .frame(height: 6)
                Text(bytes(entry.size)).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 84, alignment: .trailing)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 10).frame(height: 50)
            .contentShape(Rectangle())
            .onTapGesture { apps.toggle(entry) }

            if open {
                VStack(alignment: .leading, spacing: 4) {
                    if let items = entry.leftovers {
                        if items.isEmpty {
                            Text("No support files found in your Library.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).padding(.vertical, 4)
                        }
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                CheckBox(on: item.selected, tint: Palette.violet) { apps.toggleLeftover(item.id, in: entry.id) }
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(item.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                Spacer()
                                Text(bytes(item.size)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            .padding(.vertical, 3)
                        }
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for support files…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)) }
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        Button { Disk.reveal(entry.url) } label: { Label("Show in Finder", systemImage: "magnifyingglass") }.buttonStyle(LiquidButtonStyle(prominent: false))
                        Button {
                            if apps.isRunning(entry) { withAnimation { apps.message = "\(entry.name) is open. Quit it first, then uninstall." }; return }
                            app.confirm = ConfirmRequest(symbol: "trash.fill", title: "Uninstall \(entry.name)?",
                                message: "The app and \(bytes(entry.leftoverSize)) of ticked support files (\(bytes(entry.size + entry.leftoverSize)) in total) move to the Trash. You can put them back until you empty it.",
                                confirm: "Uninstall") { apps.uninstall(entry); app.refresh(); lens.invalidate() }
                        } label: { Label("Uninstall", systemImage: "trash.fill") }
                            .buttonStyle(LiquidButtonStyle(tint: Palette.pink)).disabled(entry.leftovers == nil)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.white.opacity(open ? 0.08 : (hover ? 0.07 : 0.025)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    let monitor: SystemMonitor
    var body: some View {
        let s = monitor.snap
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text([s.cpuTemp.map { String(format: "%.0f°", $0) }, (s.systemW ?? s.gpuW).map { String(format: "%.0fW", $0) }].compactMap { $0 }.joined(separator: " "))
                .monospacedDigit()
        }
    }
}

struct MenuBarPanel: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = monitor.snap
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                IconTile(symbol: "sparkles", tint: Palette.sky, size: 28)
                Text("Clean Silicon").font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text(degrees(s.cpuTemp)).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(heatTint(s.cpuTemp)).contentTransition(.numericText())
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                mini("CPU", "\(Int(s.cpuTotal * 100))%", monitor.cpuHistory, 1, Palette.sky)
                mini("Memory", "\(Int(s.memFraction * 100))%", monitor.memHistory, 1, Palette.violet)
                mini("Power", (s.systemW ?? s.gpuW).map { String(format: "%.1f W", $0) } ?? "—", monitor.powerHistory, nil, Palette.orange)
                mini("Network", rate(s.netDown), monitor.netHistory, nil, Palette.mint)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Macintosh HD").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(bytes(app.diskFree)) free").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DistributionBar(parts: [(Palette.sky, app.diskUsed), (.white.opacity(0.15), app.diskFree)], height: 6)
            }
            HStack {
                Button("Open Clean Silicon") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(LiquidButtonStyle())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(LiquidButtonStyle(prominent: false))
            }
        }
        .padding(16)
        .frame(width: 310)
        .preferredColorScheme(.dark)
        .onAppear { app.refresh() }
    }

    private func mini(_ title: String, _ value: String, _ history: [Double], _ ceiling: Double?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            Sparkline(values: history, ceiling: ceiling, tint: tint).frame(height: 24)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Full Disk Access check

struct AccessOverlay: View {
    @Environment(AppState.self) private var app
    @State private var shown = false
    @State private var checking = false
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let ok = app.fullDiskAccess
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 16) {
                IconTile(symbol: ok ? "checkmark.shield.fill" : "lock.shield.fill", tint: ok ? Palette.mint : Palette.orange, size: 64)
                    .symbolEffect(.bounce, value: ok)
                Text(ok ? "Full Disk Access is on" : "Clean Silicon needs Full Disk Access")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(ok ? "Every folder on this Mac can now be measured and cleaned."
                        : "macOS hides the Trash, Mail, Safari, other apps' data and parts of System Data from apps without it, so scans and sizes come up short.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if !ok {
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "Press Open Settings (Privacy & Security › Full Disk Access).")
                        step(2, "Switch on Clean Silicon. If it is not listed, press + and pick it from Applications.")
                        step(3, "Press Relaunch so macOS applies the permission.")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                HStack(spacing: 10) {
                    if ok {
                        Button("Done") { close() }.buttonStyle(LiquidButtonStyle(tint: Palette.mint)).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Not Now") { close() }.buttonStyle(LiquidButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
                        Button { recheck() } label: { Label(checking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise") }
                            .buttonStyle(LiquidButtonStyle(prominent: false))
                        Button { Disk.relaunch() } label: { Label("Relaunch", systemImage: "power") }.buttonStyle(LiquidButtonStyle(prominent: false))
                        Button { Disk.openFullDiskAccessSettings() } label: { Label("Open Settings", systemImage: "gear") }
                            .buttonStyle(LiquidButtonStyle(tint: Palette.orange))
                    }
                }
                .padding(.top, 4)
            }
            .padding(30)
            .frame(width: 600)
            .glassCard(radius: 32)
            .scaleEffect(shown ? 1 : 0.86)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.45, bounce: 0.35)) { shown = true } }
        .onReceive(poll) { _ in
            let now = Disk.hasFullDiskAccess()
            if now != app.fullDiskAccess { withAnimation(.spring) { app.fullDiskAccess = now } }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .heavy, design: .rounded)).frame(width: 20, height: 20).background(Palette.orange.opacity(0.7), in: Circle())
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recheck() {
        checking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.spring) { app.fullDiskAccess = Disk.hasFullDiskAccess(); checking = false }
        }
    }

    private func close() { withAnimation(.easeOut(duration: 0.2)) { app.showAccess = false } }
}

/// Sidebar row that always shows whether the whole disk is readable.
struct AccessStatusRow: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let ok = app.fullDiskAccess
        Button { withAnimation(.easeOut(duration: 0.2)) { app.showAccess = true } } label: {
            HStack {
                Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill").font(.system(size: 12))
                    .foregroundStyle(ok ? Palette.mint : Palette.orange)
                    .symbolEffect(.pulse, isActive: !ok)
                Text("Full Disk Access").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(ok ? "On" : "Off").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(ok ? Palette.mint : Palette.orange)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .help("Check whether Clean Silicon can read the whole disk")
    }
}
