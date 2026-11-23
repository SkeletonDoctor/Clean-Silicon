import SwiftUI

private func watts(_ w: Double?) -> String { w.map { String(format: "%.1f", $0) } ?? "—" }
private func ghz(_ mhz: Double) -> String { mhz <= 0 ? "idle" : String(format: "%.2f GHz", mhz / 1000) }

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 26).padding(.top, 44).padding(.bottom, 26)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @Environment(AppState.self) private var app
    @Environment(SystemMonitor.self) private var monitor
    @Environment(CleanerModel.self) private var cleaner
    @Environment(SpecsModel.self) private var specs

    var body: some View {
        let s = monitor.snap
        PageScroll {
            PageHeader(title: specs.machineName, subtitle: "\(specs.chip) · \(Int64(s.memTotal).formatted(.byteCount(style: .memory))) memory · macOS \(ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""))") {
                EmptyView()
            }
            HStack(spacing: 10) {
                StatusPill(symbol: "thermometer.medium", text: "CPU \(degrees(s.cpuTemp))C", tint: heatTint(s.cpuTemp))
                StatusPill(symbol: "internaldrive.fill", text: "Disk \(Int(app.diskFraction * 100))% full", tint: app.diskFraction > 0.9 ? Palette.pink : Palette.sky)
                if s.battery.present {
                    StatusPill(symbol: s.battery.charging ? "battery.100percent.bolt" : "battery.75percent",
                               text: "Battery \(s.battery.percent)% · health \(Int(s.battery.healthPct))%", tint: Palette.mint)
                }
                StatusPill(symbol: "clock.fill", text: "Up " + Duration.seconds(ProcessInfo.processInfo.systemUptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)), tint: Palette.violet)
            }
            .rise(0)
            if !app.fullDiskAccess { AccessBanner().rise(0) }

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    ZStack {
                        RingGauge(progress: app.diskFraction, lineWidth: 20)
                        VStack(spacing: 2) {
                            Text(bytes(app.diskFree)).font(.system(size: 34, weight: .bold, design: .rounded)).contentTransition(.numericText())
                            Text("available").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: 230, height: 230)
                    HStack(spacing: 26) {
                        legend("Used", bytes(app.diskUsed), Palette.sky)
                        legend("Total", bytes(app.diskTotal), .white.opacity(0.5))
                        if cleaner.scanned { legend("Reclaimable", bytes(cleaner.totalFound), Palette.mint) }
                    }
                    Button {
                        withAnimation(.spring(duration: 0.45)) { app.page = .cleaner }
                        Task { await cleaner.scan() }
                    } label: { Label(cleaner.scanned ? "Scan Again" : "Smart Scan", systemImage: "sparkles") }
                        .buttonStyle(LiquidButtonStyle(large: true))
                        .disabled(cleaner.busy)
                }
                .padding(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard()
                .hoverLift()
                .rise(1)

                VStack(spacing: 18) {
                    HStack(spacing: 18) {
                        LiveTile(title: "CPU", value: "\(Int(s.cpuTotal * 100))", unit: "%", symbol: "cpu.fill", tint: Palette.sky, history: monitor.cpuHistory, ceiling: 1,
                                 foot: "\(monitor.engine.pName) \(ghz(s.pMHz))")
                        LiveTile(title: "Memory", value: "\(Int(s.memFraction * 100))", unit: "%", symbol: "memorychip.fill", tint: Palette.violet, history: monitor.memHistory, ceiling: 1,
                                 foot: "\(bytes(Int64(s.memUsed))) in use")
                    }
                    HStack(spacing: 18) {
                        LiveTile(title: "Power", value: watts(s.systemW ?? s.gpuW), unit: "W", symbol: "bolt.fill", tint: Palette.orange, history: monitor.powerHistory, ceiling: nil,
                                 foot: s.battery.plugged ? "Adapter \(watts(s.adapterW)) W in" : "On battery")
                        LiveTile(title: "GPU", value: "\(Int(s.gpuUsage * 100))", unit: "%", symbol: "square.stack.3d.up.fill", tint: Palette.mint, history: monitor.gpuHistory, ceiling: 1,
                                 foot: "\(watts(s.gpuW)) W")
                    }
                    HStack(spacing: 18) {
                        LiveTile(title: "Temperature", value: s.cpuTemp.map { String(format: "%.0f", $0) } ?? "—", unit: "°C", symbol: "thermometer.medium", tint: heatTint(s.cpuTemp),
                                 history: monitor.tempHistory.map { max(0, $0 - 25) }, ceiling: 75, foot: "Battery \(degrees(s.batteryTemp))C · SSD \(degrees(s.ssdTemp))C")
                        LiveTile(title: "Network", value: bytes(Int64(s.netDown)).replacingOccurrences(of: " ", with: "\u{2009}"), unit: "/s", symbol: "arrow.down.circle.fill", tint: Palette.sky,
                                 history: monitor.netHistory, ceiling: nil, foot: "Up \(rate(s.netUp))")
                    }
                }
                .frame(maxWidth: .infinity)
                .rise(2)
            }

            HStack(spacing: 18) {
                quick("Space Lens", "See what is filling your disk, folder by folder", "circle.hexagongrid.fill", Palette.violet, .lens)
                quick("Uninstaller", "Remove apps and the files they leave behind", "trash.square.fill", Palette.pink, .apps)
                quick("Live Monitor", "Temperatures, per-core speeds and watts", "waveform.path.ecg", Palette.orange, .monitor)
            }
            .rise(3)
        }
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).contentTransition(.numericText())
        }
    }

    private func quick(_ title: String, _ sub: String, _ symbol: String, _ tint: Color, _ page: Page) -> some View {
        Button { withAnimation(.spring(duration: 0.45)) { app.page = page } } label: {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .glassEffect(Glass.regular.interactive(), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

struct AccessBanner: View {
    @Environment(AppState.self) private var app
    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "lock.open.fill", tint: Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn on Full Disk Access").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Without it macOS hides the Trash, Mail, Safari and other protected folders, so scans come up short.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button("Fix This") { withAnimation(.easeOut(duration: 0.2)) { app.showAccess = true } }.buttonStyle(LiquidButtonStyle(tint: Palette.orange))
        }
        .padding(16)
        .glassCard(radius: 22, tint: Palette.orange)
    }
}

struct LiveTile: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let tint: Color
    let history: [Double]
    let ceiling: Double?
    let foot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).contentTransition(.numericText()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
            Sparkline(values: history, ceiling: ceiling, tint: tint).frame(height: 34)
            Text(foot).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 22)
        .hoverLift()
    }
}

// MARK: - Cleaner

struct CleanerPage: View {
    @Environment(AppState.self) private var app
    @Environment(CleanerModel.self) private var cleaner
    @Environment(LensModel.self) private var lens

    var body: some View {
        PageScroll {
            PageHeader(title: "Cleaner", subtitle: "Find caches, logs and leftovers that inflate System Data") {
                if cleaner.scanned {
                    Button { Task { await cleaner.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .buttonStyle(LiquidButtonStyle(prominent: false)).disabled(cleaner.busy)
                }
            }
            if !app.fullDiskAccess { AccessBanner() }
            hero.rise(0)
            optionsCard.rise(1)
            if let r = cleaner.result { resultBanner(r).transition(.scale(scale: 0.9).combined(with: .opacity)) }
            ForEach(Array(cleaner.categories.enumerated()), id: \.element.id) { i, c in
                CategoryCard(category: c).rise(i + 1)
            }
            if cleaner.scanned, !cleaner.snapshots.isEmpty { snapshotCard }
            MaintenanceCard()
        }
    }

    private var optionsCard: some View {
        @Bindable var cleaner = cleaner
        return HStack(spacing: 22) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.sky)
            OptionChips(title: "Large files from", options: [("100 MB", 100), ("500 MB", 500), ("1 GB", 1000)], value: $cleaner.options.largeMB)
            OptionChips(title: "Downloads older than", options: [("30 days", 30), ("90 days", 90), ("6 months", 180)], value: $cleaner.options.downloadDays)
            Spacer(minLength: 0)
            if cleaner.scanned { Text("Applies on the next scan").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassCard(radius: 20)
    }

    private var hero: some View {
        HStack(spacing: 24) {
            ScanOrb(active: cleaner.busy, progress: cleaner.busy && !cleaner.cleaning ? cleaner.progress : (cleaner.scanned ? 1 : 0))
                .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                if cleaner.cleaning {
                    Text("Cleaning…").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Removing the selected items").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                } else if cleaner.busy {
                    Text("Scanning…").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(cleaner.scanningTitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).contentTransition(.opacity)
                } else if cleaner.scanned {
                    Text(bytes(cleaner.totalSelected)).font(.system(size: 40, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text("selected of \(bytes(cleaner.totalFound)) found").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    DistributionBar(parts: cleaner.categories.map { ($0.tint, $0.total) }).frame(maxWidth: 420).padding(.top, 6)
                } else {
                    Text("Ready to scan").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Nothing is removed until you review the results and press Clean.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            if cleaner.scanned && !cleaner.busy {
                Button { askClean() } label: { Label("Clean", systemImage: "wand.and.sparkles") }
                    .buttonStyle(LiquidButtonStyle(tint: Palette.mint, large: true))
                    .disabled(cleaner.totalSelected == 0)
            } else if !cleaner.busy {
                Button { Task { await cleaner.scan() } } label: { Label("Scan", systemImage: "sparkles") }
                    .buttonStyle(LiquidButtonStyle(large: true))
            }
        }
        .padding(24)
        .glassCard(radius: 30)
    }

    private func resultBanner(_ r: CleanResult) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: "checkmark", tint: Palette.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Freed \(bytes(r.freed))" + (r.trashed > 0 ? " · \(bytes(r.trashed)) moved to Trash" : ""))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if r.skipped > 0 {
                    Text("\(r.skipped) item\(r.skipped == 1 ? " was" : "s were") in use or protected by macOS and left in place.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer()
        }
        .padding(16)
        .glassCard(radius: 22, tint: Palette.mint)
    }

    private var snapshotCard: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "clock.arrow.circlepath", tint: Palette.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("Time Machine local snapshots · \(cleaner.snapshots.count)").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Hidden restore points counted under System Data. macOS asks for your password to remove them.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            if cleaner.snapshotBusy { ProgressView().controlSize(.small) } else {
                Button("Delete Snapshots") {
                    app.confirm = ConfirmRequest(symbol: "clock.arrow.circlepath", title: "Delete local snapshots?",
                        message: "All \(cleaner.snapshots.count) local Time Machine snapshots on this Mac are removed. Backups on your backup disk are not touched. This cannot be undone.",
                        confirm: "Delete") { Task { await cleaner.deleteSnapshots(); app.refresh(); lens.invalidate() } }
                }
                .buttonStyle(LiquidButtonStyle(tint: Palette.violet))
            }
        }
        .padding(16)
        .glassCard(radius: 22)
    }

    private func askClean() {
        let deleting = cleaner.categories.filter { $0.mode == .delete }.reduce(0) { $0 + $1.selectedSize }
        let trashing = cleaner.totalSelected - deleting
        var msg = ""
        if deleting > 0 { msg += "\(bytes(deleting)) of caches, logs and Trash items are deleted permanently. " }
        if trashing > 0 { msg += "\(bytes(trashing)) of your own files are moved to the Trash, where you can still restore them." }
        app.confirm = ConfirmRequest(symbol: "wand.and.sparkles", title: "Clean \(bytes(cleaner.totalSelected))?", message: msg, confirm: "Clean") {
            Task { await cleaner.clean(); app.refresh(); lens.invalidate() }
        }
    }
}

struct ScanOrb: View {
    let active: Bool
    let progress: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Palette.sky.opacity(0.55), Palette.violet.opacity(0.15), .clear], center: .center, startRadius: 4, endRadius: 62))
                .scaleEffect(active && spin ? 1.12 : 0.92)
                .animation(active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: spin)
            RingGauge(progress: progress, lineWidth: 9)
            if active {
                Circle().trim(from: 0, to: 0.22)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(16)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            }
            Image(systemName: active ? "sparkles" : (progress >= 1 ? "checkmark" : "sparkles"))
                .font(.system(size: 30, weight: .semibold))
                .symbolEffect(.pulse, isActive: active)
                .contentTransition(.symbolEffect(.replace))
        }
        .onAppear { spin = true }
        .animation(.spring(duration: 0.6), value: progress)
    }
}

struct CategoryCard: View {
    @Environment(CleanerModel.self) private var cleaner
    let category: CleanCategory
    @State private var hover = false

    private var index: Int { cleaner.categories.firstIndex { $0.id == category.id } ?? 0 }

    var body: some View {
        let c = category
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: c.symbol, tint: c.tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(c.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                        Badge(text: c.recommended ? "SAFE" : "REVIEW", tint: c.recommended ? Palette.mint : Palette.orange)
                        if c.mode == .trash { Badge(text: "TO TRASH", tint: .white.opacity(0.7)) }
                    }
                    Text(c.blurb).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                switch c.state {
                case .scanning: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.4)).symbolEffect(.variableColor.iterative, isActive: true)
                case .idle: EmptyView()
                case .done:
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(c.items.isEmpty ? "Clean" : bytes(c.total)).font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(c.items.isEmpty ? Palette.mint : .white).contentTransition(.numericText())
                        if !c.items.isEmpty { Text("\(c.items.count) item\(c.items.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                    }
                    if !c.items.isEmpty {
                        CheckBox(on: c.selectedCount == c.items.count, mixed: c.selectedCount > 0, tint: c.tint) {
                            cleaner.setAll(c.selectedCount != c.items.count, in: c.id)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                            .rotationEffect(.degrees(c.expanded ? 180 : 0))
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture {
                guard c.state == .done, !c.items.isEmpty else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) { cleaner.categories[index].expanded.toggle() }
            }

            if c.expanded {
                VStack(spacing: 2) {
                    ForEach(c.items.prefix(80)) { item in ItemRow(item: item, categoryID: c.id, tint: c.tint) }
                    if c.items.count > 80 {
                        Text("+ \(c.items.count - 80) smaller items").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCard(radius: 22)
        .scaleEffect(hover ? 1.006 : 1)
        .animation(.spring(duration: 0.3), value: hover)
        .onHover { hover = $0 }
    }
}

struct ItemRow: View {
    @Environment(CleanerModel.self) private var cleaner
    let item: CleanItem
    let categoryID: String
    let tint: Color
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(on: item.selected, tint: tint) {
                guard let ci = cleaner.categories.firstIndex(where: { $0.id == categoryID }),
                      let ii = cleaner.categories[ci].items.firstIndex(where: { $0.id == item.id }) else { return }
                cleaner.categories[ci].items[ii].selected.toggle()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if hover {
                Button { Disk.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IconButtonStyle()).help("Show in Finder").transition(.scale.combined(with: .opacity))
            }
            Text(bytes(item.size)).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white.opacity(hover ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Space Lens

struct LensPage: View {
    @Environment(AppState.self) private var app
    @Environment(LensModel.self) private var lens

    var body: some View {
        PageScroll {
            PageHeader(title: "Space Lens", subtitle: "Drill into any folder to see exactly where the space went") {
                HStack(spacing: 8) {
                    if lens.loading { ProgressView().controlSize(.small) }
                    Button { lens.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(LiquidButtonStyle(prominent: false))
                }
            }
            if !app.fullDiskAccess { AccessBanner() }
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(LensModel.presets, id: \.0) { p in
                            Button { lens.open(p.2) } label: { Label(p.0, systemImage: p.1) }
                                .buttonStyle(LiquidButtonStyle(tint: Palette.violet, prominent: lens.current == p.2))
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 2)
                }
            }
            .scrollIndicators(.never)
            .rise(0)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Button { lens.open(URL(fileURLWithPath: "/")) } label: { Image(systemName: "internaldrive.fill") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    ForEach(lens.crumbs, id: \.path) { u in
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                        Button(u.lastPathComponent) { lens.open(u) }.buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: u == lens.crumbs.last ? .bold : .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(u == lens.crumbs.last ? 1 : 0.6))
                    }
                    Spacer()
                    Text(bytes(lens.total)).font(.system(size: 15, weight: .bold, design: .rounded)).contentTransition(.numericText())
                }
                .padding(.horizontal, 6).padding(.bottom, 4)

                if lens.total > 0 {
                    let top = Array(lens.entries.prefix(6))
                    let rest = lens.total - top.reduce(0) { $0 + ($1.size ?? 0) }
                    DistributionBar(parts: top.enumerated().map { (Palette.ranked[$0.offset], $0.element.size ?? 0) } + [(.white.opacity(0.25), rest)], height: 14)
                        .padding(.horizontal, 6)
                    HStack(spacing: 14) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, e in
                            HStack(spacing: 5) {
                                Circle().fill(Palette.ranked[i]).frame(width: 7, height: 7)
                                Text(e.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                if lens.denied {
                    Text("macOS blocked this folder. Turn on Full Disk Access for Clean Silicon to look inside.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(20).frame(maxWidth: .infinity)
                } else if lens.entries.isEmpty {
                    Text("This folder is empty").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(20).frame(maxWidth: .infinity)
                }
                LazyVStack(spacing: 3) {
                    ForEach(Array(lens.entries.prefix(150).enumerated()), id: \.element.id) { i, e in
                        LensRow(entry: e, largest: lens.largest, tint: i < 6 ? Palette.ranked[i] : .white.opacity(0.45))
                    }
                }
            }
            .padding(16)
            .glassCard()
            .rise(1)
        }
        .onAppear { if lens.entries.isEmpty { lens.open(lens.current) } }
    }
}

struct LensRow: View {
    @Environment(AppState.self) private var app
    @Environment(LensModel.self) private var lens
    let entry: LensEntry
    let largest: Int64
    var tint: Color = Palette.sky
    @State private var hover = false

    var body: some View {
        let fraction = largest > 0 ? Double(entry.size ?? 0) / Double(largest) : 0
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 14)).foregroundStyle(entry.isDirectory ? Palette.sky : .white.opacity(0.55)).frame(width: 20)
            Text(entry.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(width: 230, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(tint.gradient)
                        .frame(width: max(entry.size == nil ? 0 : 4, g.size.width * fraction))
                }
            }
            .frame(height: 6)
            if hover {
                Button { Disk.reveal(entry.url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(IconButtonStyle()).help("Show in Finder")
                Button {
                    app.confirm = ConfirmRequest(symbol: "trash.fill", title: "Move “\(entry.name)” to the Trash?",
                        message: "\(bytes(entry.size ?? 0)) will move to the Trash. Only remove things you recognise: deleting system or app support folders can break apps.",
                        confirm: "Move to Trash") { lens.trash(entry); app.refresh() }
                } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle(tint: Palette.pink)).help("Move to Trash")
            }
            Group {
                if let s = entry.size { Text(bytes(s)).contentTransition(.numericText()) } else { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
            .frame(width: 84, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(entry.isDirectory ? 0.4 : 0))
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(.white.opacity(hover ? 0.09 : 0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if entry.isDirectory { lens.open(entry.url) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Monitor

struct MonitorPage: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snap
        let e = monitor.engine
        PageScroll {
            PageHeader(title: "Monitor", subtitle: "Live readings straight from the chip, refreshed every second") {
                Badge(text: thermalText(s.thermal).uppercased(), tint: thermalTint(s.thermal))
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.fill").foregroundStyle(Palette.orange)
                        Text("Power draw").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(watts(s.systemW ?? s.gpuW)).font(.system(size: 52, weight: .bold, design: .rounded)).contentTransition(.numericText()).monospacedDigit()
                        Text("watts").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                    }
                    Sparkline(values: monitor.powerHistory, ceiling: nil, tint: Palette.orange).frame(height: 70)
                    HStack(spacing: 18) {
                        stat("Adapter in", "\(watts(s.adapterW)) W")
                        stat(s.battery.flowW >= 0 ? "To battery" : "From battery", String(format: "%.1f W", abs(s.battery.flowW)))
                        stat("GPU", "\(watts(s.gpuW)) W")
                        if let c = s.cpuW { stat("CPU", "\(watts(c)) W") }
                        stat("Peak", String(format: "%.1f W", monitor.peakW))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(spacing: 14) {
                    gauge("CPU", s.cpuTotal, [Palette.sky, Palette.violet, Palette.sky])
                    HStack(spacing: 14) {
                        miniGauge("GPU", s.gpuUsage, Palette.mint)
                        miniGauge("Memory", s.memFraction, Palette.violet)
                    }
                }
                .padding(20)
                .frame(width: 300)
                .glassCard()
            }
            .rise(0)

            HStack(spacing: 18) {
                TemperatureCard()
                NetworkCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            .rise(1)

            FanStrip().rise(1)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Cores").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    cluster(e.pName, s.pMHz, e.pTable.max() ?? 0, Palette.orange)
                    cluster(e.eName, s.eMHz, e.eTable.max() ?? 0, Palette.mint)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(s.cores) { c in CoreBar(core: c) }
                    if s.cores.isEmpty {
                        Text("Per-core counters are not available on this Mac.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .glassCard()
            .rise(1)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Memory").font(.system(size: 15, weight: .semibold, design: .rounded))
                    let parts: [(String, UInt64, Color)] = [("Apps", s.memApp, Palette.sky), ("Wired", s.memWired, Palette.orange),
                                                              ("Compressed", s.memCompressed, Palette.pink), ("Cached files", s.memCached, Palette.mint)]
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(parts, id: \.0) { p in
                                Capsule().fill(p.2.gradient).frame(width: max(3, g.size.width * Double(p.1) / Double(max(s.memTotal, 1))))
                            }
                            Capsule().fill(.white.opacity(0.08))
                        }
                    }
                    .frame(height: 12)
                    HStack(spacing: 16) {
                        ForEach(parts, id: \.0) { p in
                            HStack(spacing: 5) { Circle().fill(p.2).frame(width: 7, height: 7); stat(p.0, bytes(Int64(p.1))) }
                        }
                        stat("Swap", bytes(Int64(s.swapUsed)))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                if s.battery.present {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Battery").font(.system(size: 15, weight: .semibold, design: .rounded))
                            Spacer()
                            Image(systemName: s.battery.charging ? "battery.100percent.bolt" : "battery.75percent").foregroundStyle(Palette.mint)
                            Text("\(s.battery.percent)%").font(.system(size: 15, weight: .bold, design: .rounded)).contentTransition(.numericText())
                        }
                        HStack(spacing: 16) {
                            stat("Health", String(format: "%.0f%%", s.battery.healthPct))
                            stat("Cycles", "\(s.battery.cycles)")
                            if s.battery.tempC > 0 { stat("Temp", String(format: "%.1f °C", s.battery.tempC)) }
                            stat("Voltage", String(format: "%.2f V", s.battery.volts))
                            if s.battery.adapterW > 0 { stat("Charger", "\(s.battery.adapterW) W") }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
                }
            }
            .rise(2)

            ProcessCard().rise(3)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
        }
    }

    private func cluster(_ name: String, _ mhz: Double, _ maxMHz: Double, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            Text(ghz(mhz)).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            if maxMHz > 0 { Text("of " + String(format: "%.2f", maxMHz / 1000)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.white.opacity(0.07), in: Capsule())
    }

    private func gauge(_ label: String, _ v: Double, _ colors: [Color]) -> some View {
        ZStack {
            RingGauge(progress: v, colors: colors, lineWidth: 13)
            VStack(spacing: 0) {
                Text("\(Int(v * 100))%").font(.system(size: 30, weight: .bold, design: .rounded)).contentTransition(.numericText()).monospacedDigit()
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 140, height: 140)
    }

    private func miniGauge(_ label: String, _ v: Double, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RingGauge(progress: v, colors: [tint, tint.opacity(0.6), tint], lineWidth: 6)
                Text("\(Int(v * 100))").font(.system(size: 13, weight: .bold, design: .rounded)).contentTransition(.numericText())
            }
            .frame(width: 48, height: 48)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func thermalText(_ t: ProcessInfo.ThermalState) -> String {
        switch t { case .nominal: "Thermals normal"; case .fair: "Warm"; case .serious: "Hot · throttling"; case .critical: "Critical heat"; @unknown default: "Unknown" }
    }
    private func thermalTint(_ t: ProcessInfo.ThermalState) -> Color {
        switch t { case .nominal: Palette.mint; case .fair: Palette.orange; default: Palette.pink }
    }
}

struct CoreBar: View {
    let core: CoreStat
    var body: some View {
        let tint = core.isPerformance ? Palette.orange : Palette.mint
        VStack(spacing: 6) {
            Text("\(Int(core.usage * 100))%").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                    .frame(height: max(4, 110 * core.usage))
                    .shadow(color: tint.opacity(0.6), radius: 8)
            }
            .frame(height: 110)
            .frame(maxWidth: 46)
            Text(core.label).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(core.mhz > 0 ? String(format: "%.1f", core.mhz / 1000) : "–").font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.55)).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Specs

struct SpecsPage: View {
    @Environment(SpecsModel.self) private var specs
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        PageScroll {
            PageHeader(title: "Specs", subtitle: "\(specs.machineName) · \(specs.chip)") {
                Button {
                    let text = specs.sections.map { s in "\(s.title)\n" + s.rows.map { "  \($0.label): \($0.value)" }.joined(separator: "\n") }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .buttonStyle(LiquidButtonStyle(prominent: false))
            }
            if specs.sections.isEmpty {
                HStack { Spacer(); ProgressView("Reading hardware…").padding(60); Spacer() }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(Array(specs.sections.enumerated()), id: \.element.id) { i, sec in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            IconTile(symbol: sec.symbol, tint: [Palette.sky, Palette.orange, Palette.violet, Palette.mint, Palette.pink, Palette.sky][i % 6], size: 32)
                            Text(sec.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                        }
                        VStack(spacing: 0) {
                            ForEach(sec.rows) { r in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(r.label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                                    Spacer(minLength: 12)
                                    Text(r.value).font(.system(size: 12.5, weight: .medium)).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }
                                .padding(.vertical, 7)
                                if r.id != sec.rows.last?.id { Divider().opacity(0.35) }
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .glassCard(radius: 24)
                    .rise(i)
                }
            }
        }
    }
}
