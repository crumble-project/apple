import SwiftUI

/// Paints one frame of a bot. Lengths are fractions of `size`; the body sits low enough in the
/// square to leave room for its topper above and its shadow below.
struct BotCanvas: View {
  let look: BotLook
  let size: CGFloat
  let pose: BotPose
  let expression: BotExpression
  var expressions: [(BotExpression, Double)]?

  var body: some View {
    Canvas { context, _ in
      BotPainter(look: look, size: size, pose: pose, expression: expression)
        .paint(&context, expressions: expressions)
    }
    .frame(width: size, height: size)
  }
}

/// A piece of a bot drawn on its own at rest, for the layer-driven live avatar.
enum BotPart: Hashable {
  case shadow, topper, glow, body, closedEyes
  case eye(left: Bool)
  case mouth(BotExpression)
}

/// One part of a bot in the full square, so every part lines up when stacked.
struct BotPartCanvas: View {
  let look: BotLook
  let size: CGFloat
  let part: BotPart

  var body: some View {
    Canvas { context, _ in
      BotPainter(look: look, size: size, pose: BotPose(mouthOpen: 1, glow: 1), expression: .calm)
        .paint(part, &context)
    }
    .frame(width: size, height: size)
  }
}

/// The points a bot moves around, at rest, in points from the top left.
struct BotGeometry {
  /// The middle of the body's base, where it squashes and rolls.
  let base: CGPoint
  /// Where the topper is planted and swings from.
  let topper: CGPoint
  let leftEye: CGPoint
  let rightEye: CGPoint
  let mouth: CGPoint
  let shadow: CGPoint
  /// How far the eyes can squash shut, as a fraction of their open height.
  let shutScale: Double

  init(look: BotLook, size: CGFloat) {
    let painter = BotPainter(look: look, size: size, pose: .rest, expression: .calm)
    let bounds = BotBody(shape: look.shape).path(in: painter.frame).boundingRect
    base = CGPoint(x: bounds.midX, y: bounds.maxY)
    shadow = CGPoint(x: bounds.midX, y: bounds.maxY + size * 0.055 * 0.05)
    topper = painter.topperBase
    leftEye = painter.eyeCenter(-1)
    rightEye = painter.eyeCenter(1)
    mouth = painter.mouthCenter
    shutScale = 0.55 * 0.068 / 0.145
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

struct BotPainter {
  // swiftlint:disable:previous type_body_length
  let look: BotLook
  let size: CGFloat
  let pose: BotPose
  let expression: BotExpression

  var frame: CGRect { CGRect(x: size * 0.04, y: size * 0.1, width: size * 0.92, height: size * 0.92) }
  private var layout: BotLayout { BotLayout(look.shape) }
  private var detailed: Bool { size >= 22 }

  private func point(_ unit: CGPoint) -> CGPoint {
    CGPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height)
  }

  /// Paints one part at rest; open mouths and the antenna glow are drawn at their fullest.
  func paint(_ part: BotPart, _ context: inout GraphicsContext) {
    let body = BotBody(shape: look.shape).path(in: frame)
    switch part {
    case .shadow: paintShadow(&context, under: body.boundingRect)
    case .topper: BotPainter(look: look, size: size, pose: .rest, expression: expression).paintTopper(&context)
    case .glow: if look.topper == .antenna { paintGlow(&context) }
    case .body: paintBody(&context, body, body.boundingRect)
    case .eye(let left): paintEye(&context, at: eyeCenter(left ? -1 : 1))
    case .closedEyes:
      for side in [-1.0, 1.0] { paintClosedEye(&context, at: eyeCenter(side)) }
    case .mouth(let expression):
      BotPainter(look: look, size: size, pose: pose, expression: expression).paintMouth(&context)
    }
  }

  var topperBase: CGPoint { point(CGPoint(x: layout.top.x, y: layout.top.y + 0.06)) }

  func eyeCenter(_ side: Double) -> CGPoint {
    CGPoint(
      x: faceCenter.x + unit * side * 0.0875 + size * pose.gazeX,
      y: faceCenter.y - unit * 0.045 + size * pose.gazeY)
  }

  var mouthCenter: CGPoint {
    CGPoint(
      x: faceCenter.x - unit * 0.012 + size * pose.gazeX * 0.65,
      y: faceCenter.y + unit * 0.125 + size * pose.gazeY * 0.65)
  }

  func paint(_ context: inout GraphicsContext, expressions: [(BotExpression, Double)]?) {
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
    if let expressions {
      for (expression, opacity) in expressions where opacity > 0 {
        var face = figure
        face.opacity *= opacity
        BotPainter(look: look, size: size, pose: pose, expression: expression).paintFace(&face)
      }
    } else {
      paintFace(&figure)
    }
  }

  private func paintShadow(_ context: inout GraphicsContext, under bounds: CGRect) {
    let rise = min(1, pose.lift * 9)
    let width = bounds.width * 0.66 * pose.scaleX * (1 - 0.35 * rise)
    let height = size * 0.055 * (1 - 0.3 * rise)
    let oval = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - height * 0.45, width: width, height: height)
    softOval(&context, in: oval.insetBy(dx: -size * 0.012, dy: -size * 0.012),
         color: .black.opacity(0.2 * (1 - 0.55 * rise)))
  }

  private func paintBody(_ context: inout GraphicsContext, _ body: Path, _ bounds: CGRect) {
    paintSurface(&context, body, bounds)
    var inside = context
    inside.clip(to: body)
    if detailed { paintCheeks(&inside) }
    paintRim(&context, body)
  }

  // MARK: Face

  private var faceCenter: CGPoint { point(layout.face) }
  private var unit: Double { size * layout.faceScale }

  private func paintCheeks(_ context: inout GraphicsContext) {
    let glow = expression == .delighted ? 0.22 : 0.12
    for side in [-1.0, 1.0] {
      let center = CGPoint(
        x: faceCenter.x + unit * (side * 0.175 + pose.gazeX * 0.5 / layout.faceScale - 0.01),
        y: faceCenter.y + unit * 0.085 + size * pose.gazeY * 0.5)
      softOval(&context,
           in: CGRect(x: center.x - unit * 0.045, y: center.y - unit * 0.025,
                width: unit * 0.09, height: unit * 0.05),
           color: look.blushColor.opacity(glow))
    }
  }

  private func paintFace(_ context: inout GraphicsContext) {
    for side in [-1.0, 1.0] {
      let center = eyeCenter(side)
      if expression == .asleep {
        paintClosedEye(&context, at: center)
      } else {
        paintEye(&context, at: center)
      }
    }
    paintMouth(&context)
  }

  private func paintEye(_ context: inout GraphicsContext, at center: CGPoint) {
    let width = unit * 0.068
    let height = max(width * 0.55, unit * 0.145 * pose.lid)
    var eye = context
    eye.translateBy(x: center.x, y: center.y)
    eye.rotate(by: .degrees(-8))
    let shape = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    eye.fill(Path(roundedRect: shape, cornerRadius: min(width, height) / 2), with: .color(look.inkColor))
    guard detailed, pose.lid > 0.6 else { return }
    let spark = width * 0.25
    eye.fill(
      Path(ellipseIn: CGRect(x: -width * 0.28, y: -height * 0.36, width: spark, height: spark)),
      with: .color(.white.opacity(0.5)))
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
    let center = mouthCenter
    let ink = GraphicsContext.Shading.color(look.inkColor)
    let line = StrokeStyle(lineWidth: max(0.8, unit * 0.026), lineCap: .round, lineJoin: .round)
    switch expression {
    case .asleep:
      context.fill(oval(center, unit * 0.034, unit * (0.022 + 0.016 * pose.mouthOpen)), with: ink)
    case .focused:
      context.fill(oval(center, unit * 0.046, unit * (0.03 + 0.022 * pose.mouthOpen)), with: ink)
    case .delighted:
      paintGrin(&context, center, width: unit * 0.105, depth: unit * 0.035)
    case .calm:
      switch look.mouth {
      case .smile: context.stroke(smile(center, unit * 0.1, unit * 0.025), with: ink, style: line)
      case .tiny: context.stroke(smile(center, unit * 0.06, unit * 0.015), with: ink, style: line)
      case .grin: paintGrin(&context, center, width: unit * 0.09, depth: unit * 0.025)
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
    var inside = context
    inside.clip(to: grin)
    inside.fill(
      oval(CGPoint(x: center.x, y: center.y + depth * 0.95), width * 0.32, depth * 0.45),
      with: .color(Color(red: 1, green: 0.45, blue: 0.55)))
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

  private func softOval(_ context: inout GraphicsContext, in rect: CGRect, color: Color) {
    var soft = context
    soft.translateBy(x: rect.midX, y: rect.midY)
    soft.scaleBy(x: rect.width / 2, y: rect.height / 2)
    soft.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
         with: .radialGradient(Gradient(colors: [color, color.opacity(0.65), .clear]),
                    center: .zero, startRadius: 0, endRadius: 1))
  }

  // MARK: Topper

  /// The antenna's halo and lit ball, on its own so the live avatar can fade it in and out.
  private func paintGlow(_ context: inout GraphicsContext) {
    var lit = context
    lit.translateBy(x: topperBase.x, y: topperBase.y)
    paintBall(&lit, glow: 1)
  }

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
    paintBall(&context, glow: pose.glow)
  }

  private func paintBall(_ context: inout GraphicsContext, glow: Double) {
    let tip = CGPoint(x: 0, y: -size * 0.16)
    let radius = size * 0.058
    let ball = oval(tip, radius * 2, radius * 2)
    if glow > 0 {
      let halo = radius + size * 0.07 * glow
      softOval(&context, in: CGRect(x: tip.x - halo, y: tip.y - halo, width: halo * 2, height: halo * 2),
           color: look.tint(0.5).opacity(glow * 0.6))
    }
    context.fill(
      ball,
      with: look.finish != .glossy ? .color(look.tint(0.4 + 0.3 * glow)) : .radialGradient(
        Gradient(colors: [.white, look.tint(0.45 + 0.3 * glow), look.tint(0.1)]),
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
