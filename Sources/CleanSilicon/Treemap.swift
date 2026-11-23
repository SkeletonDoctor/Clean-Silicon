import SwiftUI

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rectangles whose areas match `values`,
/// kept as close to square as possible. `values` must be sorted largest first.
enum Squarify {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let sum = values.reduce(0, +)
        guard sum > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / sum
        let areas = values.map { $0 * scale }
        var out: [CGRect] = []
        var free = rect
        var row: [Double] = []

        func worst(_ row: [Double], _ side: Double) -> Double {
            guard let hi = row.first, let lo = row.last, lo > 0 else { return .infinity }
            let s = row.reduce(0, +)
            return max(side * side * hi / (s * s), s * s / (side * side * lo))
        }
        func place() {
            let s = row.reduce(0, +)
            guard s > 0 else { row = []; return }
            if free.width >= free.height {
                let w = CGFloat(s) / free.height
                var y = free.minY
                for a in row { let h = CGFloat(a) / w; out.append(CGRect(x: free.minX, y: y, width: w, height: h)); y += h }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(0, free.width - w), height: free.height)
            } else {
                let h = CGFloat(s) / free.width
                var x = free.minX
                for a in row { let w = CGFloat(a) / h; out.append(CGRect(x: x, y: free.minY, width: w, height: h)); x += w }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(0, free.height - h))
            }
            row = []
        }
        for a in areas {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [a], side) <= worst(row, side) { row.append(a) } else { place(); row.append(a) }
        }
        place()
        return out
    }
}

struct MapTile: Identifiable {
    let id: String
    let entry: LensEntry?      // nil for the "smaller items" tile
    let name: String
    let size: Int64
    let rect: CGRect
    let tint: Color
}

/// Disk usage of the open folder as a map: every block's area is its share of the folder,
/// and folders show their own largest contents inside.
struct TreemapView: View {
    @Environment(AppState.self) private var app
    @Environment(LensModel.self) private var lens
    @State private var hovered: String?

    static let hues: [Color] = Palette.ranked + [
        Color(red: 0.32, green: 0.85, blue: 0.9), Color(red: 0.5, green: 0.6, blue: 1.0),
        Color(red: 1.0, green: 0.55, blue: 0.45), Color(red: 0.62, green: 0.88, blue: 0.45),
    ]

    private func tiles(in size: CGSize) -> [MapTile] {
        let sized = lens.entries.filter { ($0.size ?? 0) > 0 }
        let total = Double(sized.reduce(0) { $0 + ($1.size ?? 0) })
        guard total > 0 else { return [] }
        // Blocks too small to read are pooled into one.
        let floor = total * 900 / Double(max(1, size.width * size.height))
        var shown = Array(sized.prefix(36).prefix { Double($0.size ?? 0) >= floor })
        if shown.isEmpty { shown = Array(sized.prefix(1)) }
        let rest = sized.dropFirst(shown.count)
        let restSize = rest.reduce(0) { $0 + ($1.size ?? 0) }
        var values = shown.map { Double($0.size ?? 0) }
        if restSize > 0 { values.append(max(Double(restSize), floor * 0.6)) }
        let rects = Squarify.layout(values, in: CGRect(origin: .zero, size: size))
        var out = shown.enumerated().map { i, e in
            MapTile(id: e.id, entry: e, name: e.name, size: e.size ?? 0, rect: rects[i], tint: Self.hues[i % Self.hues.count])
        }
        if restSize > 0 {
            out.append(MapTile(id: "·rest", entry: nil, name: "\(rest.count) smaller item\(rest.count == 1 ? "" : "s")", size: restSize, rect: rects[shown.count], tint: .white.opacity(0.55)))
        }
        return out
    }

    var body: some View {
        let total = lens.total
        VStack(spacing: 10) {
            GeometryReader { g in
                let tiles = tiles(in: g.size)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.22))
                    if tiles.isEmpty {
                        VStack(spacing: 8) {
                            if lens.loading { ProgressView().controlSize(.small) }
                            Text(lens.loading ? "Measuring this folder…" : (lens.denied ? "macOS blocked this folder" : "Nothing here takes up space"))
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(tiles) { t in
                        TileView(tile: t, hovered: hovered == t.id, dimmed: hovered != nil && hovered != t.id)
                            .frame(width: max(0, t.rect.width - 3), height: max(0, t.rect.height - 3))
                            .offset(x: t.rect.minX + 1.5, y: t.rect.minY + 1.5)
                            .zIndex(hovered == t.id ? 2 : 1)
                            .onHover { h in
                                withAnimation(.easeOut(duration: 0.14)) { if h { hovered = t.id } else if hovered == t.id { hovered = nil } }
                            }
                            .onTapGesture { if let e = t.entry, e.isDirectory { hovered = nil; lens.open(e.url) } }
                            .contextMenu { if let e = t.entry { menu(e) } }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.5, bounce: 0.18), value: tiles.map(\.id))
                .animation(.spring(duration: 0.5, bounce: 0.18), value: tiles.map(\.size))
            }
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            detail(total: total)
        }
    }

    /// One line under the map describing the block under the pointer.
    private func detail(total: Int64) -> some View {
        let entry = lens.entries.first { $0.id == hovered }
        return HStack(spacing: 8) {
            if let e = entry, let size = e.size {
                Image(systemName: e.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 12)).foregroundStyle(Palette.sky)
                Text(e.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(bytes(size)).font(.system(size: 12.5, weight: .bold, design: .rounded)).monospacedDigit()
                if total > 0 { Badge(text: String(format: "%.1f%% of this folder", Double(size) / Double(total) * 100), tint: Palette.sky) }
                Spacer(minLength: 8)
                Text(e.isDirectory ? "Click to look inside · right-click for more" : "Right-click for more")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            } else if hovered == "·rest" {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Text("Items too small to draw. They are all in the list below.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                Image(systemName: "cursorarrow.motionlines").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                Text(lens.loading ? "Measuring \(lens.measured) of \(lens.entries.count) items…" : "Bigger blocks take more space. Click a folder to look inside.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).contentTransition(.numericText())
                Spacer()
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 6)
    }

    @ViewBuilder private func menu(_ e: LensEntry) -> some View {
        if e.isDirectory { Button("Look Inside") { lens.open(e.url) } }
        Button("Show in Finder") { Disk.reveal(e.url) }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            app.confirm = ConfirmRequest(symbol: "trash.fill", title: "Move “\(e.name)” to the Trash?",
                message: "\(bytes(e.size ?? 0)) will move to the Trash. Only remove things you recognise: deleting system or app support folders can break apps.",
                confirm: "Move to Trash") { lens.trash(e); app.refresh() }
        }
    }
}

private struct TileView: View {
    let tile: MapTile
    let hovered: Bool
    let dimmed: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let radius = min(13, min(w, h) / 3.2)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let titled = w > 58 && h > 24
            let header: CGFloat = titled ? (h > 46 ? 42 : 24) : 0
            ZStack(alignment: .topLeading) {
                shape.fill(LinearGradient(colors: [tile.tint.opacity(hovered ? 0.62 : 0.46), tile.tint.opacity(hovered ? 0.34 : 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let kids = tile.entry?.kids, !kids.isEmpty, w > 70, h - header > 34 {
                    Inside(kids: kids, total: tile.size, tint: tile.tint)
                        .padding(.init(top: max(header, 6), leading: 6, bottom: 6, trailing: 6))
                }
                if titled {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            if w > 90, let e = tile.entry {
                                Image(systemName: e.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85))
                            }
                            Text(tile.name).font(.system(size: w > 150 ? 12.5 : 11.5, weight: .semibold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                        }
                        if h > 46 {
                            Text(bytes(tile.size)).font(.system(size: w > 150 ? 12 : 11, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.72)).lineLimit(1).contentTransition(.numericText())
                        }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(.horizontal, 9).padding(.top, 7)
                    .frame(width: w, alignment: .leading)
                }
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(hovered ? 0.75 : 0.3), tile.tint.opacity(hovered ? 0.9 : 0.35)], startPoint: .top, endPoint: .bottom), lineWidth: hovered ? 1.4 : 0.8)
            }
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: tile.tint.opacity(hovered ? 0.5 : 0), radius: 14)
            .opacity(dimmed ? 0.62 : 1)
        }
    }
}

/// The second level: a folder's own largest items, drawn inside its block.
private struct Inside: View {
    let kids: [LensKid]
    let total: Int64
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            // What the listed items don't account for stays as an empty slot of the right size.
            var slots: [(value: Double, kid: LensKid?)] = kids.filter { $0.size > 0 }.map { (Double($0.size), $0) }
            let rest = total - kids.reduce(0) { $0 + $1.size }
            if rest > 0 { slots.append((Double(rest), nil)) }
            slots.sort { $0.value > $1.value }
            let rects = Squarify.layout(slots.map(\.value), in: CGRect(origin: .zero, size: size))
            for (i, r) in rects.enumerated() {
                guard let kid = slots[i].kid else { continue }
                let box = r.insetBy(dx: 1.2, dy: 1.2)
                guard box.width > 3, box.height > 3 else { continue }
                let path = Path(roundedRect: box, cornerRadius: min(6, min(box.width, box.height) / 3), style: .continuous)
                let weight = total > 0 ? Double(kid.size) / Double(total) : 0
                ctx.fill(path, with: .color(.black.opacity(0.16 + 0.1 * (1 - weight))))
                ctx.fill(path, with: .color(.white.opacity(0.05 + 0.12 * weight)))
                ctx.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: 0.6)
                if box.width > 54, box.height > 17 {
                    let name = ctx.resolve(Text(kid.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.82)))
                    let twoLines = box.height > 32
                    ctx.draw(name, in: CGRect(x: box.minX + 5, y: box.minY + 3, width: box.width - 9, height: 13))
                    if twoLines {
                        let sz = ctx.resolve(Text(bytes(kid.size)).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5)))
                        ctx.draw(sz, in: CGRect(x: box.minX + 5, y: box.minY + 16, width: box.width - 9, height: 12))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
