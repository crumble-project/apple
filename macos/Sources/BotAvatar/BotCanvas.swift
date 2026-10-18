import SwiftUI

/// Paints one frame of a bot. Lengths are fractions of `size`; the body sits low enough in the
/// square to leave room for its topper above and its shadow below.
struct BotCanvas: View {
    let look: BotLook
    let size: CGFloat
    let pose: BotPose
    let expression: BotExpression

    var body: some View {
        Canvas { context, _ in
            BotPainter(look: look, size: size, pose: pose, expression: expression).paint(&context)
        }
        .frame(width: size, height: size)
    }
}

/// Where a shape's face and topper sit, as fractions of the body's frame, and how big the face is.
private struct BotLayout {
    let face: CGPoint
    let faceScale: Double
    let top: CGPoint

    init(_ shape: BotShape) {
        switch shape {
        case .circle, .squircle:
            (face, faceScale, top) = (CGPoint(x: 0.6, y: 0.47), 1, CGPoint(x: 0.5, y: 0.08))
        case .hexagon:
            (face, faceScale, top) = (CGPoint(x: 0.58, y: 0.49), 0.95, CGPoint(x: 0.5, y: 0.08))
        case .pill:
            (face, faceScale, top) = (CGPoint(x: 0.6, y: 0.49), 0.8, CGPoint(x: 0.5, y: 0.23))
        case .triangle:
            (face, faceScale, top) = (CGPoint(x: 0.54, y: 0.64), 0.78, CGPoint(x: 0.5, y: 0.08))
        case .cloud:
            (face, faceScale, top) = (CGPoint(x: 0.56, y: 0.52), 0.85, CGPoint(x: 0.53, y: 0.12))
        case .drop:
            (face, faceScale, top) = (CGPoint(x: 0.54, y: 0.62), 0.9, CGPoint(x: 0.5, y: 0.08))
        }
    }
}

private struct BotPainter {
    let look: BotLook
    let size: CGFloat
    let pose: BotPose
    let expression: BotExpression

    private var frame: CGRect { CGRect(x: size * 0.04, y: size * 0.1, width: size * 0.92, height: size * 0.92) }
    private var layout: BotLayout { BotLayout(look.shape) }
    private var detailed: Bool { size >= 22 }

    private func point(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height)
    }

    func paint(_ context: inout GraphicsContext) {
        let body = BotBody(shape: look.shape).path(in: frame)
        let bounds = body.boundingRect
        paintShadow(&context, under: bounds)

        var figure = context
        let base = CGPoint(x: bounds.midX, y: bounds.maxY)
        figure.translateBy(x: 0, y: -size * pose.lift)
        figure.translateBy(x: base.x, y: base.y)
        figure.scaleBy(x: pose.scaleX, y: pose.scaleY)
        figure.rotate(by: .degrees(pose.roll))
        figure.translateBy(x: -base.x, y: -base.y)

        paintTopper(&figure)
        paintBody(&figure, body, bounds)
        paintFace(&figure)
    }

    private func paintShadow(_ context: inout GraphicsContext, under bounds: CGRect) {
        let rise = min(1, pose.lift * 9)
        let width = bounds.width * 0.66 * pose.scaleX * (1 - 0.35 * rise)
        let height = size * 0.055 * (1 - 0.3 * rise)
        let oval = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - height * 0.45, width: width, height: height)
        var soft = context
        soft.addFilter(.blur(radius: size * 0.012))
        soft.fill(Path(ellipseIn: oval), with: .color(.black.opacity(0.2 * (1 - 0.55 * rise))))
    }

    private func paintBody(_ context: inout GraphicsContext, _ body: Path, _ bounds: CGRect) {
        context.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [look.tint(0.22), look.color, look.tint(-0.16)]),
                startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
        context.drawLayer { inside in
            inside.clip(to: body)
            let sheen = CGRect(
                x: bounds.minX + bounds.width * 0.08, y: bounds.minY + bounds.height * 0.02,
                width: bounds.width * 0.55, height: bounds.height * 0.42)
            inside.fill(
                Path(ellipseIn: sheen),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.42), .white.opacity(0)]),
                    center: CGPoint(x: sheen.midX, y: sheen.midY), startRadius: 0, endRadius: sheen.width / 2))
            inside.stroke(
                body.offsetBy(dx: -size * 0.02, dy: -size * 0.03), with: .color(look.tint(-0.3).opacity(0.28)),
                lineWidth: size * 0.05)
            if detailed { paintCheeks(&inside) }
        }
        context.stroke(body, with: .color(look.tint(-0.45).opacity(0.3)), lineWidth: max(0.6, size * 0.01))
    }

    // MARK: Face

    private var faceCenter: CGPoint { point(layout.face) }
    private var unit: Double { size * layout.faceScale }

    private func paintCheeks(_ context: inout GraphicsContext) {
        let glow = expression == .delighted ? 1.0 : 0.75
        var soft = context
        soft.addFilter(.blur(radius: size * 0.012))
        for side in [-1.0, 1.0] {
            let center = CGPoint(
                x: faceCenter.x + unit * (side * 0.175 + pose.gazeX * 0.5 / layout.faceScale - 0.01),
                y: faceCenter.y + unit * 0.085 + size * pose.gazeY * 0.5)
            soft.fill(
                oval(center, unit * 0.085, unit * 0.05), with: .color(look.blushColor.opacity(glow)))
        }
    }

    private func paintFace(_ context: inout GraphicsContext) {
        for side in [-1.0, 1.0] {
            let center = CGPoint(
                x: faceCenter.x + unit * side * 0.0875 + size * pose.gazeX,
                y: faceCenter.y - unit * 0.045 + size * pose.gazeY)
            if expression == .asleep {
                paintClosedEye(&context, at: center)
            } else {
                paintEye(&context, at: center)
            }
        }
        paintMouth(&context)
    }

    private func paintEye(_ context: inout GraphicsContext, at center: CGPoint) {
        let width = unit * 0.078
        let height = max(width * 0.55, unit * 0.2 * pose.lid)
        var eye = context
        eye.translateBy(x: center.x, y: center.y)
        eye.rotate(by: .degrees(-18))
        let shape = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        eye.fill(Path(roundedRect: shape, cornerRadius: min(width, height) / 2), with: .color(look.inkColor))
        guard detailed, pose.lid > 0.6 else { return }
        let spark = width * 0.42
        eye.fill(
            Path(ellipseIn: CGRect(x: -width * 0.28, y: -height * 0.36, width: spark, height: spark)),
            with: .color(.white.opacity(0.92)))
        if size >= 48 {
            let glint = width * 0.2
            eye.fill(
                Path(ellipseIn: CGRect(x: width * 0.02, y: height * 0.12, width: glint, height: glint)),
                with: .color(.white.opacity(0.55)))
        }
    }

    private func paintClosedEye(_ context: inout GraphicsContext, at center: CGPoint) {
        let half = unit * 0.05
        var lid = Path()
        lid.move(to: CGPoint(x: center.x - half, y: center.y + unit * 0.02))
        lid.addQuadCurve(
            to: CGPoint(x: center.x + half, y: center.y + unit * 0.005),
            control: CGPoint(x: center.x, y: center.y + unit * 0.065))
        context.stroke(
            lid, with: .color(look.inkColor), style: StrokeStyle(lineWidth: unit * 0.034, lineCap: .round))
    }

    private func paintMouth(_ context: inout GraphicsContext) {
        let center = CGPoint(
            x: faceCenter.x - unit * 0.012 + size * pose.gazeX * 0.65,
            y: faceCenter.y + unit * 0.125 + size * pose.gazeY * 0.65)
        let ink = GraphicsContext.Shading.color(look.inkColor)
        let line = StrokeStyle(lineWidth: max(0.8, unit * 0.026), lineCap: .round, lineJoin: .round)
        switch expression {
        case .asleep:
            context.fill(oval(center, unit * 0.034, unit * (0.022 + 0.016 * pose.mouthOpen)), with: ink)
        case .focused:
            context.fill(oval(center, unit * 0.046, unit * (0.03 + 0.022 * pose.mouthOpen)), with: ink)
        case .delighted:
            paintGrin(&context, center, width: unit * 0.13, depth: unit * 0.075)
        case .calm:
            switch look.mouth {
            case .smile: context.stroke(smile(center, unit * 0.1, unit * 0.05), with: ink, style: line)
            case .tiny: context.stroke(smile(center, unit * 0.06, unit * 0.03), with: ink, style: line)
            case .grin: paintGrin(&context, center, width: unit * 0.1, depth: unit * 0.055)
            case .cat:
                var cat = smile(CGPoint(x: center.x - unit * 0.026, y: center.y), unit * 0.052, unit * 0.03)
                cat.addPath(smile(CGPoint(x: center.x + unit * 0.026, y: center.y), unit * 0.052, unit * 0.03))
                context.stroke(cat, with: ink, style: line)
            }
        }
    }

    private func paintGrin(_ context: inout GraphicsContext, _ center: CGPoint, width: Double, depth: Double) {
        var grin = Path()
        grin.move(to: CGPoint(x: center.x - width / 2, y: center.y - depth * 0.25))
        grin.addLine(to: CGPoint(x: center.x + width / 2, y: center.y - depth * 0.25))
        grin.addQuadCurve(
            to: CGPoint(x: center.x - width / 2, y: center.y - depth * 0.25),
            control: CGPoint(x: center.x, y: center.y + depth * 1.6))
        grin.closeSubpath()
        context.fill(grin, with: .color(look.inkColor))
        guard detailed else { return }
        context.drawLayer { inside in
            inside.clip(to: grin)
            inside.fill(
                oval(CGPoint(x: center.x, y: center.y + depth * 0.95), width * 0.32, depth * 0.45),
                with: .color(Color(red: 1, green: 0.45, blue: 0.55)))
        }
    }

    private func smile(_ center: CGPoint, _ width: Double, _ depth: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x - width / 2, y: center.y - depth / 2))
        path.addQuadCurve(
            to: CGPoint(x: center.x + width / 2, y: center.y - depth / 2),
            control: CGPoint(x: center.x, y: center.y + depth * 1.1))
        return path
    }

    private func oval(_ center: CGPoint, _ width: Double, _ height: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
    }

    // MARK: Topper

    private func paintTopper(_ context: inout GraphicsContext) {
        guard look.topper != .none else { return }
        let base = point(CGPoint(x: layout.top.x, y: layout.top.y + 0.06))
        var topper = context
        topper.translateBy(x: base.x, y: base.y)
        topper.rotate(by: .degrees(pose.sway))
        switch look.topper {
        case .none: break
        case .antenna: paintAntenna(&topper)
        case .sprout: paintSprout(&topper)
        case .tuft: paintTuft(&topper)
        }
    }

    private func paintAntenna(_ context: inout GraphicsContext) {
        let tip = CGPoint(x: 0, y: -size * 0.16)
        var stalk = Path()
        stalk.move(to: .zero)
        stalk.addQuadCurve(to: tip, control: CGPoint(x: size * 0.025, y: -size * 0.09))
        context.stroke(
            stalk, with: .color(look.tint(-0.35)), style: StrokeStyle(lineWidth: size * 0.036, lineCap: .round))
        let radius = size * 0.058
        let ball = oval(tip, radius * 2, radius * 2)
        var light = context
        if pose.glow > 0 {
            light.addFilter(.shadow(color: look.tint(0.5).opacity(pose.glow), radius: size * 0.05 * pose.glow))
        }
        light.fill(
            ball,
            with: .radialGradient(
                Gradient(colors: [.white, look.tint(0.45 + 0.3 * pose.glow), look.tint(0.1)]),
                center: CGPoint(x: tip.x - radius * 0.35, y: tip.y - radius * 0.35), startRadius: 0,
                endRadius: radius * 1.4))
    }

    private func paintSprout(_ context: inout GraphicsContext) {
        let green = look.hex == "#22c55e" || look.hex == "#14b8a6" ? Color(red: 0.75, green: 0.95, blue: 0.39)
            : Color(red: 0.29, green: 0.85, blue: 0.5)
        let top = CGPoint(x: 0, y: -size * 0.1)
        var stem = Path()
        stem.move(to: .zero)
        stem.addQuadCurve(to: top, control: CGPoint(x: -size * 0.02, y: -size * 0.05))
        context.stroke(
            stem, with: .color(green.mix(with: .black, by: 0.3)),
            style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
        for side in [-1.0, 1.0] {
            var leaf = context
            leaf.translateBy(x: top.x, y: top.y)
            leaf.rotate(by: .degrees(side * 50 - 8))
            let blade = oval(CGPoint(x: 0, y: -size * 0.05), size * 0.075, size * 0.115)
            leaf.fill(blade, with: .linearGradient(
                Gradient(colors: [green.mix(with: .white, by: 0.25), green]),
                startPoint: CGPoint(x: 0, y: -size * 0.1), endPoint: .zero))
        }
    }

    private func paintTuft(_ context: inout GraphicsContext) {
        let ink = look.tint(-0.3)
        for (angle, length) in [(-28.0, 0.085), (0.0, 0.11), (28.0, 0.08)] {
            var strand = context
            strand.rotate(by: .degrees(angle))
            var hair = Path()
            hair.move(to: .zero)
            hair.addQuadCurve(
                to: CGPoint(x: size * 0.035, y: -size * length),
                control: CGPoint(x: -size * 0.03, y: -size * length * 0.6))
            strand.stroke(hair, with: .color(ink), style: StrokeStyle(lineWidth: size * 0.034, lineCap: .round))
        }
    }
}
