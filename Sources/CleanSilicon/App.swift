import SwiftUI

@main
struct CleanSiliconApp: App {
    @State private var app = AppState()
    @State private var monitor = SystemMonitor()
    @State private var cleaner = CleanerModel()
    @State private var lens = LensModel()
    @State private var specs = SpecsModel()
    @State private var apps = AppsModel()
    @State private var maintenance = MaintenanceModel()
    @State private var stress = StressModel()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); exit(0) }
        if CommandLine.arguments.contains("--stresscheck") { SelfTest.stress(); exit(0) }
    }

    var body: some Scene {
        Window("Clean Silicon", id: "main") {
            RootView()
                .environment(app).environment(monitor).environment(cleaner).environment(lens).environment(specs).environment(apps).environment(maintenance).environment(stress)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 790)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel().environment(app).environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(SystemMonitor.self) private var monitor
    @Environment(SpecsModel.self) private var specs
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: 0) {
                Sidebar()
                ZStack {
                    switch app.page {
                    case .overview: OverviewPage()
                    case .cleaner: CleanerPage()
                    case .lens: LensPage()
                    case .apps: AppsPage()
                    case .monitor: MonitorPage()
                    case .stress: StressPage()
                    case .specs: SpecsPage()
                    }
                }
                .id(app.page)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if app.showAccess { AccessOverlay().transition(.opacity).zIndex(9) }
            if let c = app.confirm { ConfirmOverlay(request: c).transition(.opacity).zIndex(10) }
        }
        .ignoresSafeArea()
        .onAppear { app.refresh(); specs.load(engine: monitor.engine); if !app.fullDiskAccess, !UserDefaults.standard.bool(forKey: "quiet") { app.showAccess = true } }
        .onChange(of: phase) { _, p in if p == .active { app.refresh() } }
    }
}

struct Sidebar: View {
    @Environment(AppState.self) private var app
    @Namespace private var ns
    @AppStorage("showMenuBar") private var showMenuBar = true

    private func group(_ title: String?, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).kerning(1.2)
                    .foregroundStyle(.white.opacity(0.38)).padding(.leading, 12).padding(.top, 12)
            }
            ForEach(pages) { page in
                NavItem(page: page, selected: app.page == page, ns: ns) {
                    withAnimation(.spring(duration: 0.45, bounce: 0.25)) { app.page = page }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconTile(symbol: "sparkles", tint: Palette.sky, size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Clean").font(.system(size: 15, weight: .heavy, design: .rounded))
                    Text("Silicon").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.top, 46).padding(.bottom, 10).padding(.leading, 6)

            group(nil, [.overview])
            group("CLEAN UP", [.cleaner, .lens, .apps])
            group("SYSTEM", [.monitor, .stress, .specs])
            Spacer()
            AccessStatusRow()
            UpdateRow()
            HStack {
                Image(systemName: "menubar.rectangle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Text("Menu bar stats").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                GlassToggle(isOn: $showMenuBar)
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Macintosh HD").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(app.diskFraction * 100))%").font(.system(size: 11, weight: .bold, design: .rounded)).contentTransition(.numericText())
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(LinearGradient(colors: [Palette.mint, Palette.sky, Palette.violet], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * app.diskFraction))
                    }
                }
                .frame(height: 6)
                Text("\(bytes(app.diskFree)) free").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(14)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .glassEffect(Glass.regular, in: .rect(cornerRadius: 28))
        .padding(.leading, 10).padding(.vertical, 10)
    }
}

struct NavItem: View {
    let page: Page
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                    .symbolEffect(.bounce, value: selected)
                    .foregroundStyle(selected ? Palette.sky : .white.opacity(0.75))
                Text(page.rawValue).font(.system(size: 13.5, weight: selected ? .semibold : .medium, design: .rounded))
                Spacer()
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
                        .shadow(color: Palette.sky.opacity(0.35), radius: 12)
                        .matchedGeometryEffect(id: "nav", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct ConfirmOverlay: View {
    @Environment(AppState.self) private var app
    let request: ConfirmRequest
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { dismiss() }
            VStack(spacing: 14) {
                IconTile(symbol: request.symbol, tint: Palette.pink, size: 54)
                Text(request.title).font(.system(size: 19, weight: .bold, design: .rounded))
                Text(request.message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }.buttonStyle(LiquidButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
                    Button(request.confirm) { dismiss(); request.action() }.buttonStyle(LiquidButtonStyle(tint: Palette.pink))
                }
                .padding(.top, 6)
            }
            .padding(28)
            .frame(width: 400)
            .glassCard(radius: 30)
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.35)) { shown = true } }
    }

    private func dismiss() { withAnimation(.easeOut(duration: 0.2)) { app.confirm = nil } }
}

enum SelfTest {
    /// Runs each stress worker for a few seconds and prints its rate.
    static func stress() {
        let log: LogFn = { level, source, text in print("[\(level.tag)] [\(source)] \(text)") }
        func run(_ name: String, seconds: Double, unit: Double, _ body: @escaping @Sendable (StopFlag, Meter) -> Void) {
            let stop = StopFlag(), meter = Meter(), done = DispatchSemaphore(value: 0)
            Thread { body(stop, meter); done.signal() }.start()
            Thread.sleep(forTimeInterval: seconds); stop.set(); done.wait()
            print("\(name): \(String(format: "%.1f", meter.total / seconds / unit)) per s, errors \(meter.errors) \(meter.note)")
        }
        run("cpu 1 thread MB", seconds: 3, unit: 1) { s, m in StressWorkers.cpu(stop: s, meter: m) }
        run("gpu Mpx", seconds: 4, unit: 1) { s, m in StressWorkers.gpu(stop: s, meter: m, log: log) }
        run("mem GB", seconds: 4, unit: 1e9) { s, m in StressWorkers.memory(targetBytes: 1 << 30, stop: s, meter: m, log: log) }
        run("disk MB", seconds: 4, unit: 1e6) { s, m in StressWorkers.disk(maxPasses: 1, stop: s, meter: m, log: log) }
    }

    static func run() {
        let e = MetricsEngine()
        _ = e.read(); Thread.sleep(forTimeInterval: 1)
        let s = e.read()
        print("cpu \(Int(s.cpuTotal * 100))%  gpu \(Int(s.gpuUsage * 100))%  mem \(bytes(Int64(s.memUsed)))/\(bytes(Int64(s.memTotal)))  swap \(bytes(Int64(s.swapUsed)))")
        print("power system=\(s.systemW ?? -1)W adapter=\(s.adapterW ?? -1)W cpu=\(s.cpuW ?? -1)W gpu=\(s.gpuW ?? -1)W batteryFlow=\(s.battery.flowW)W")
        print("clusters \(e.eName)=\(Int(s.eMHz))MHz \(e.pName)=\(Int(s.pMHz))MHz  tables e=\(e.eTable.map { Int($0) }) p=\(e.pTable.map { Int($0) })")
        print("cores " + s.cores.map { "\($0.label):\(Int($0.usage * 100))%@\(Int($0.mhz))" }.joined(separator: " "))
        print("battery \(s.battery)")
        print("temps cpu=\(s.cpuTemp ?? -1) max=\(s.cpuTempMax ?? -1) batt=\(s.batteryTemp ?? -1) ssd=\(s.ssdTemp ?? -1)  net down=\(rate(s.netDown)) up=\(rate(s.netUp))")
        print("top cpu " + s.topCPU.prefix(3).map { "\($0.name)=\($0.cpu)%" }.joined(separator: ", ") + " | mem " + s.topMemory.prefix(3).map { "\($0.name)=\(bytes($0.memory))" }.joined(separator: ", "))
        let installed = AppScanner.installed()
        print("apps \(installed.count), top: " + installed.prefix(3).map { "\($0.name)=\(bytes($0.size)) leftovers=\(AppScanner.leftovers(name: $0.name, bundleID: $0.bundleID).map { $0.detail + "/" + $0.name })" }.joined(separator: " ; "))
        let specs = SpecsLoader.load(engine: e)
        for sec in specs.sections { print("[\(sec.title)] " + sec.rows.map { "\($0.label)=\($0.value)" }.joined(separator: "; ")) }
        let v = Disk.volume()
        print("disk total \(bytes(v.total)) free \(bytes(v.free)) fda \(Disk.hasFullDiskAccess()) snapshots \(Disk.localSnapshots().count)")
        print("fans \(s.fans.map { "\($0.count)" } ?? "unreadable")")
        for id in ["caches", "logs", "xcode", "dev", "mail", "trash", "system", "ios", "downloads", "simulators", "installers", "screenshots", "duplicates", "large"] {
            let items = CleanerScanner.scan(id, preselect: false)
            print("scan \(id): \(items.count) items, \(bytes(items.reduce(0) { $0 + $1.size }))  top: \(items.prefix(2).map { "\($0.name)=\(bytes($0.size))" })")
        }
    }
}
