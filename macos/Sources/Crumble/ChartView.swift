import apfelkern
import SwiftUI

/// Draws a chart the bot server compiled, picking the layout that fits and showing a tooltip for the hovered point.
struct ChartView: View {
    let chart: DisplayComponent.Chart
    @Environment(\.colorScheme) private var colorScheme
    @State private var available: Double = 0
    @State private var hovered: ChartPoint?

    var body: some View {
        if let layout = chart.layout(fitting: available > 0 ? available : .infinity) {
            let scale = available > 0 ? min(1, available / layout.width) : 1
            Canvas { context, _ in
                context.scaleBy(x: scale, y: scale)
                let palette = ChartPaint.Resolver(dark: colorScheme == .dark)
                for node in layout.nodes {
                    draw(node, in: context, palette: palette)
                }
                if let hovered {
                    let ring = Path(ellipseIn: CGRect(x: hovered.x - 5, y: hovered.y - 5, width: 10, height: 10))
                    context.fill(ring, with: .color(palette.color(.background)))
                    context.stroke(
                        ring, with: .color(palette.color(hovered.color ?? .foreground)), lineWidth: 2.5)
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovered = nearest(in: layout, to: location, scale: scale)
                case .ended:
                    hovered = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered {
                    ChartTooltip(point: hovered)
                        .alignmentGuide(.leading) { size in
                            min(max(hovered.x * scale - size.width / 2, 0), layout.width * scale - size.width) * -1
                        }
                        .alignmentGuide(.top) { size in
                            (hovered.y * scale - size.height - 10 < 0
                                ? hovered.y * scale + 12 : hovered.y * scale - size.height - 10) * -1
                        }
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { available = $0 }
            .accessibilityElement()
            .accessibilityLabel(chart.title ?? "Chart")
            .accessibilityValue(summary(layout))
        }
    }

    private func nearest(in layout: ChartLayout, to location: CGPoint, scale: Double) -> ChartPoint? {
        let x = location.x / scale
        let y = location.y / scale
        return layout.points
            .map { ($0, hypot($0.x - x, $0.y - y)) }
            .filter { $0.1 <= 32 }
            .min { $0.1 < $1.1 }?.0
    }

    private func summary(_ layout: ChartLayout) -> String {
        layout.points.prefix(30).map { point in
            ([point.title, point.text].compactMap(\.self) + point.rows.map { "\($0.label) \($0.value)" })
                .joined(separator: ", ")
        }
        .joined(separator: "; ")
    }

    private func draw(_ node: ChartNode, in parent: GraphicsContext, palette: ChartPaint.Resolver) {
        switch node {
        case .line(let x1, let y1, let x2, let y2, let paint):
            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            paint.render(path, in: parent, palette: palette, defaultFill: .none)
        case .path(let commands, let evenOdd, let paint):
            paint.render(Path(commands), in: parent, palette: palette, evenOdd: evenOdd)
        case .circle(let x, let y, let radius, let paint):
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            paint.render(Path(ellipseIn: rect), in: parent, palette: palette)
        case .rect(let x, let y, let width, let height, let radius, let paint):
            let rect = CGRect(x: x, y: y, width: width, height: height)
            paint.render(Path(roundedRect: rect, cornerRadius: radius), in: parent, palette: palette)
        case .text(let label, let paint):
            paint.render(label, in: parent, palette: palette)
        case .unsupported:
            break
        }
    }
}

private struct ChartTooltip: View {
    let point: ChartPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = point.title {
                Text(title).font(.caption.weight(.semibold))
            }
            if let text = point.text {
                Text(text).font(.caption)
            }
            ForEach(Array(point.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(row.value).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

extension Path {
    fileprivate init(_ commands: [ChartPathCommand]) {
        self.init()
        for command in commands {
            switch command {
            case .move(let x, let y): move(to: CGPoint(x: x, y: y))
            case .line(let x, let y): addLine(to: CGPoint(x: x, y: y))
            case .quad(let controlX, let controlY, let x, let y):
                addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: controlX, y: controlY))
            case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
                addCurve(
                    to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: closeSubpath()
            }
        }
    }
}

extension ChartPaint {
    /// Resolves theme tokens for the current appearance.
    fileprivate struct Resolver {
        let dark: Bool

        func color(_ color: ChartColor) -> Color {
            switch color {
            case .none: .clear
            case .foreground: .primary
            case .background: Color(nsColor: .windowBackgroundColor)
            case .series(let slot): self.color(ChartPalette.series(slot, dark: dark))
            case .rgba(let red, let green, let blue, let alpha):
                Color(red: red, green: green, blue: blue, opacity: alpha)
            }
        }
    }

    /// A copy of the context with this primitive's clip and opacity applied.
    private func scoped(_ parent: GraphicsContext) -> GraphicsContext {
        var context = parent
        if let clip, clip.count == 4 {
            context.clip(to: Path(CGRect(x: clip[0], y: clip[1], width: clip[2], height: clip[3])))
        }
        context.opacity = opacity ?? 1
        return context
    }

    /// SVG semantics: an unset fill paints the foreground, an unset stroke paints nothing.
    fileprivate func render(
        _ path: Path, in parent: GraphicsContext, palette: Resolver, evenOdd: Bool = false,
        defaultFill: ChartColor = .foreground
    ) {
        let context = scoped(parent)
        let fill = fill ?? defaultFill
        if fill != .none {
            context.fill(
                path, with: .color(palette.color(fill).opacity(fillOpacity ?? 1)), style: FillStyle(eoFill: evenOdd))
        }
        if let stroke, stroke != .none {
            context.stroke(path, with: .color(palette.color(stroke).opacity(strokeOpacity ?? 1)), style: strokeStyle)
        }
    }

    fileprivate func render(_ label: ChartText, in parent: GraphicsContext, palette: Resolver) {
        var context = scoped(parent)
        let weight: Font.Weight = label.weight >= 600 ? .semibold : label.weight >= 500 ? .medium : .regular
        let text = Text(label.text)
            .font(.system(size: label.size, weight: weight))
            .foregroundStyle(palette.color(fill ?? .foreground).opacity(fillOpacity ?? 1))
        let anchor = UnitPoint(
            x: label.anchor == "middle" ? 0.5 : label.anchor == "end" ? 1 : 0,
            // An alphabetic baseline sits about 80% down a system font's line box.
            y: label.baseline == "middle" ? 0.5 : label.baseline == "hanging" ? 0 : 0.8)
        context.translateBy(x: label.x, y: label.y)
        context.rotate(by: .degrees(label.rotate))
        context.draw(text, at: .zero, anchor: anchor)
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: strokeWidth ?? 1,
            lineCap: lineCap == "round" ? .round : lineCap == "square" ? .square : .butt,
            lineJoin: lineJoin == "round" ? .round : lineJoin == "bevel" ? .bevel : .miter,
            dash: (dash ?? []).map { CGFloat($0) })
    }
}
