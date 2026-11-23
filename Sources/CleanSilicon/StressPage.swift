import SwiftUI
import AppKit

private func sampled(_ a: [Double]) -> [Double] {
    guard a.count > 60 else { return a }
    return (0..<60).map { a[$0 * (a.count - 1) / 59] }
}

struct StressPage: View {
    @Environment(StressModel.self) private var stress
    @Environment(SystemMonitor.self) private var monitor
    @Environment(SpecsModel.self) private var specs
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var stress = stress
        let s = monitor.snap
        let busy = stress.running || stress.stopping
        PageScroll {
            PageHeader(title: "Stress Test", subtitle: "Load every component at once and record how the Mac holds up") {
                if stress.running {
                    Button { stress.finish(reason: "stopped by user") } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(LiquidButtonStyle(tint: Palette.pink, large: true))
                } else {
                    Button { ask() } label: { Label(stress.stopping ? "Finishing…" : "Start Test", systemImage: "flame.fill") }
                        .buttonStyle(LiquidButtonStyle(tint: Palette.orange, large: true))
                        .disabled(stress.stopping || stress.selected.isEmpty)
                }
            }

            HStack(spacing: 14) {
                ForEach(StressComponent.allCases) { c in ComponentCard(component: c, busy: busy) }
            }
            .rise(0)

            HStack(spacing: 22) {
                OptionChips(title: "Duration", options: [("30 s", 30), ("1 min", 60), ("5 min", 300), ("15 min", 900)], value: $stress.durationSec)
                    .disabled(busy).opacity(busy ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(busy ? "Running" : (stress.summary.isEmpty ? "Idle" : "Finished")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text("\(Int(stress.elapsed)) / \(stress.durationSec) s").font(.system(size: 11.5, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    }
                    DistributionBar(parts: [(Palette.orange, Int64(stress.progress * 1000)), (.white.opacity(0.1), Int64((1 - stress.progress) * 1000) + 1)], height: 8)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassCard(radius: 20)
            .rise(1)

            HStack(spacing: 14) {
                trace("Temperature", degrees(s.cpuTemp) + "C", "thermometer.medium", heatTint(s.cpuTemp), sampled(stress.tempTrace.map { max(0, $0 - 25) }), 85)
                trace("Power", String(format: "%.1f W", s.systemW ?? 0), "bolt.fill", Palette.orange, sampled(stress.powerTrace), nil)
                VStack(alignment: .leading, spacing: 8) {
                    line("\(monitor.engine.pName) clock", String(format: "%.2f GHz", s.pMHz / 1000))
                    line("\(monitor.engine.eName) clock", String(format: "%.2f GHz", s.eMHz / 1000))
                    line("Thermal state", StressModel.name(s.thermal).capitalized)
                    line("CPU · GPU", "\(Int(s.cpuTotal * 100))% · \(Int(s.gpuUsage * 100))%")
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).glassCard(radius: 22)
            }
            .fixedSize(horizontal: false, vertical: true)
            .rise(2)

            if !stress.summary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "checkmark.seal.fill", tint: Palette.mint, size: 32)
                        Text("Results").font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 8) {
                        ForEach(stress.summary) { r in line(r.label, r.value) }
                    }
                }
                .padding(18).glassCard(radius: 22, tint: Palette.mint)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            LogConsole().rise(3)
        }
        .onAppear {
            // Developer hook: `-autostress <seconds>` starts a run on launch, for automated checks.
            let auto = UserDefaults.standard.integer(forKey: "autostress")
            if auto > 0, !busy, stress.lines.isEmpty { stress.durationSec = auto; stress.start(monitor: monitor, machine: specs.machineName, chip: specs.chip) }
        }
    }

    private func ask() {
        app.confirm = ConfirmRequest(symbol: "flame.fill", title: "Start the stress test?",
            message: "The Mac will run hot and feel slow for \(stress.durationSec) seconds, and drain the battery quickly if unplugged. Save your work first. It stops by itself at 110 °C, a critical thermal state or critical memory pressure.",
            confirm: "Start") { stress.start(monitor: monitor, machine: specs.machineName, chip: specs.chip) }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit().multilineTextAlignment(.trailing).contentTransition(.numericText())
        }
    }

    private func trace(_ title: String, _ value: String, _ symbol: String, _ tint: Color, _ values: [Double], _ ceiling: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            }
            Sparkline(values: values, ceiling: ceiling, tint: tint).frame(height: 62)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius: 22)
    }
}

struct ComponentCard: View {
    @Environment(StressModel.self) private var stress
    let component: StressComponent
    let busy: Bool
    @State private var hover = false

    var body: some View {
        let on = stress.selected.contains(component)
        Button {
            guard !busy else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { if on { stress.selected.remove(component) } else { stress.selected.insert(component) } }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    IconTile(symbol: component.symbol, tint: component.tint, size: 36)
                        .symbolEffect(.pulse, isActive: stress.running && on)
                    Spacer()
                    CheckBox(on: on, tint: component.tint) {}.allowsHitTesting(false)
                }
                Text(component.rawValue).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(stress.live[component] ?? component.blurb)
                    .font(.system(size: stress.live[component] == nil ? 11 : 13, weight: stress.live[component] == nil ? .regular : .bold, design: .rounded))
                    .foregroundStyle(stress.live[component] == nil ? .white.opacity(0.55) : component.tint)
                    .lineLimit(2).multilineTextAlignment(.leading).monospacedDigit().contentTransition(.numericText())
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(Glass.regular.tint(component.tint.opacity(on ? 0.2 : 0)).interactive(), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
            .opacity(on ? 1 : 0.6)
            .scaleEffect(hover && !busy ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
    }
}

struct LogConsole: View {
    @Environment(StressModel.self) private var stress

    var body: some View {
        @Bindable var stress = stress
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").foregroundStyle(Palette.sky)
                Text("Log").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("\(stress.lines.count) lines").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                OptionChips(title: "", options: [("Everything", 0), ("Info", 1), ("Warnings", 2), ("Errors", 3)],
                            value: Binding(get: { stress.minLevel.rawValue }, set: { stress.minLevel = LogLevel(rawValue: $0) ?? .debug }))
                Button {
                    let text = stress.lines.map { String(format: "[+%07.2fs] [%@] [%@] %@", $0.elapsed, $0.level.tag, $0.source, $0.text) }.joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(IconButtonStyle()).help("Copy the whole log")
                Button { if let u = stress.logURL { Disk.reveal(u) } } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle()).help("Show the log and CSV files in Finder").disabled(stress.logURL == nil)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(stress.visible) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(String(format: "%7.1fs", l.elapsed)).foregroundStyle(.white.opacity(0.35))
                                Text(l.level.tag).foregroundStyle(l.level.tint).fontWeight(.bold)
                                Text(l.source).foregroundStyle(.white.opacity(0.6)).frame(width: 48, alignment: .leading)
                                Text(l.text).foregroundStyle(l.level >= .warn ? l.level.tint : .white.opacity(l.level == .debug ? 0.6 : 0.9)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .id(l.id)
                        }
                    }
                    .padding(12)
                }
                .frame(height: 280)
                .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .center) {
                    if stress.lines.isEmpty {
                        Text("Timestamped events, per-second telemetry, throttling warnings and results appear here.\nEverything is also saved to ~/Library/Logs/Clean Silicon as a .log and a .csv, and sent to Console.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                    }
                }
                .onChange(of: stress.lines.count) { _, _ in if let last = stress.visible.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(18)
        .glassCard()
    }
}
