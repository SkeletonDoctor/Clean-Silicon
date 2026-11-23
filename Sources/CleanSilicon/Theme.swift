import SwiftUI

enum Palette {
    static let sky = Color(red: 0.36, green: 0.74, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.92, blue: 0.76)
    static let violet = Color(red: 0.66, green: 0.52, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.66, blue: 0.32)
    static let pink = Color(red: 1.0, green: 0.45, blue: 0.62)
}

/// Slowly drifting colour field that gives the glass something to refract.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { ctx in
            let t = Float(ctx.date.timeIntervalSinceReferenceDate) * 0.22
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + 0.12 * sin(t), 0], [1, 0],
                [0, 0.5 + 0.14 * cos(t * 0.8)], [0.5 + 0.2 * sin(t * 0.7), 0.5 + 0.2 * cos(t * 0.9)], [1, 0.5 + 0.14 * sin(t * 1.1)],
                [0, 1], [0.5 + 0.12 * cos(t * 0.6), 1], [1, 1],
            ], colors: [
                Color(red: 0.03, green: 0.05, blue: 0.14), Color(red: 0.05, green: 0.16, blue: 0.34), Color(red: 0.10, green: 0.06, blue: 0.26),
                Color(red: 0.02, green: 0.22, blue: 0.34), Color(red: 0.16, green: 0.20, blue: 0.52), Color(red: 0.30, green: 0.10, blue: 0.42),
                Color(red: 0.02, green: 0.10, blue: 0.16), Color(red: 0.04, green: 0.26, blue: 0.30), Color(red: 0.08, green: 0.05, blue: 0.18),
            ])
        }
        .overlay(Color.black.opacity(0.18))
        .ignoresSafeArea()
    }
}

extension View {
    func glassCard(radius: CGFloat = 26, tint: Color? = nil) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? Glass.regular, in: .rect(cornerRadius: radius))
    }
}

/// Capsule glass button with press, hover and glow animation.
struct LiquidButtonStyle: ButtonStyle {
    var tint: Color = Palette.sky
    var prominent = true
    var large = false

    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, style: self) }

    private struct Inner: View {
        let configuration: Configuration
        let style: LiquidButtonStyle
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: style.large ? 16 : 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, style.large ? 28 : 16)
                .padding(.vertical, style.large ? 14 : 9)
                .glassEffect(Glass.regular.tint(style.tint.opacity(style.prominent ? 0.6 : 0.12)).interactive(), in: .capsule)
                .contentShape(.capsule)
                .shadow(color: style.tint.opacity(style.prominent ? (hover ? 0.55 : 0.25) : 0), radius: hover ? 18 : 10, y: 4)
                .scaleEffect(configuration.isPressed ? 0.95 : (hover ? 1.035 : 1))
                .opacity(enabled ? 1 : 0.45)
                .animation(.spring(duration: 0.3, bounce: 0.4), value: configuration.isPressed)
                .animation(.spring(duration: 0.3), value: hover)
                .onHover { hover = $0 }
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, tint: tint) }

    private struct Inner: View {
        let configuration: Configuration
        let tint: Color
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? tint : .white.opacity(0.75))
                .frame(width: 28, height: 28)
                .glassEffect(Glass.regular.interactive(), in: .circle)
                .contentShape(.circle)
                .scaleEffect(configuration.isPressed ? 0.88 : (hover ? 1.1 : 1))
                .animation(.spring(duration: 0.25, bounce: 0.45), value: configuration.isPressed)
                .animation(.spring(duration: 0.25), value: hover)
                .onHover { hover = $0 }
        }
    }
}

struct CheckBox: View {
    let on: Bool
    var mixed = false
    var tint: Color = Palette.sky
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on || mixed ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.white.opacity(0.08)))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(on || mixed ? 0.5 : 0.28), lineWidth: 1)
                Image(systemName: mixed && !on ? "minus" : "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .scaleEffect(on || mixed ? 1 : 0.2)
                    .opacity(on || mixed ? 1 : 0)
            }
            .frame(width: 22, height: 22)
            .animation(.spring(duration: 0.28, bounce: 0.5), value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RingGauge: View {
    var progress: Double
    var colors: [Color] = [Palette.mint, Palette.sky, Palette.violet]
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[1].opacity(0.6), radius: 10)
        }
        .padding(lineWidth / 2)
    }
}

struct Sparkline: View {
    var values: [Double]
    var ceiling: Double? = 1
    var tint: Color = Palette.sky

    private func path(in size: CGSize, closed: Bool) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let top = max(ceiling ?? (values.max() ?? 1) * 1.15, 0.0001)
        let step = size.width / CGFloat(59)
        let offset = size.width - step * CGFloat(values.count - 1)
        let pts = values.enumerated().map { CGPoint(x: offset + CGFloat($0.offset) * step, y: size.height * (1 - CGFloat(min($0.element / top, 1)) * 0.94) - 1) }
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        if closed {
            p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            p.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            p.closeSubpath()
        }
        return p
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                path(in: geo.size, closed: true).fill(LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                path(in: geo.size, closed: false).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: tint.opacity(0.7), radius: 5)
            }
        }
    }
}

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient.opacity(0.85), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.8))
            .shadow(color: tint.opacity(0.45), radius: 8, y: 3)
    }
}

struct Badge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            trailing
        }
    }
}

/// Fades and lifts content in when it first appears.
struct Rise: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.25).delay(delay)) { shown = true } }
    }
}

extension View {
    func rise(_ index: Int) -> some View { modifier(Rise(delay: Double(index) * 0.06)) }
}
