import SwiftUI

/// The surface a bot's body is painted with. Every finish shades the same way, lit from the top
/// left, so bots keep their volume whichever one an app picks.
public enum BotFinish: String, CaseIterable, Identifiable, Sendable {
  case glossy, matte, dither, halftone, grain, outline

  public var id: Self { self }
}

extension EnvironmentValues {
  /// The finish for bot avatars below this point.
  @Entry public var botFinish = BotFinish.glossy
}

extension BotPainter {
  /// Fills the body; cheeks and the rim are painted over it afterwards.
  func paintSurface(_ context: inout GraphicsContext, _ body: Path, _ bounds: CGRect) {
    var inside = context
    inside.clip(to: body)
    switch look.finish {
    case .glossy:
      paintGloss(&context, &inside, body, bounds)
    case .matte:
      context.fill(
        body,
        with: .linearGradient(
          Gradient(colors: [look.tint(0.08), look.color, look.tint(-0.1)]),
          startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
      inside.stroke(
        body.offsetBy(dx: -size * 0.02, dy: -size * 0.03), with: .color(look.tint(-0.3).opacity(0.18)),
        lineWidth: size * 0.06)
    case .dither:
      context.fill(body, with: .color(look.color))
      paintDither(&inside, bounds)
    case .halftone:
      context.fill(body, with: .color(look.color))
      paintHalftone(&inside, bounds)
    case .grain:
      context.fill(
        body,
        with: .linearGradient(
          Gradient(colors: [look.tint(0.1), look.tint(-0.08)]),
          startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
      paintGrain(&inside, bounds)
    case .outline:
      context.fill(body, with: .color(look.color))
      inside.stroke(
        body.offsetBy(dx: -size * 0.035, dy: -size * 0.045), with: .color(look.tint(-0.16)),
        lineWidth: size * 0.09)
      let glint = CGRect(
        x: bounds.minX + bounds.width * 0.2, y: bounds.minY + bounds.height * 0.14,
        width: bounds.width * 0.14, height: bounds.height * 0.08)
      inside.fill(Path(ellipseIn: glint), with: .color(.white.opacity(0.55)))
    }
  }

  /// The rim around the body: a hairline for most finishes, a bold ink line for `.outline`.
  func paintRim(_ context: inout GraphicsContext, _ body: Path) {
    if look.finish == .outline {
      context.stroke(body, with: .color(look.inkColor), lineWidth: max(1, size * 0.035))
    } else {
      context.stroke(body, with: .color(look.tint(-0.45).opacity(0.3)), lineWidth: max(0.6, size * 0.01))
    }
  }

  private func paintGloss(
    _ context: inout GraphicsContext, _ inside: inout GraphicsContext, _ body: Path, _ bounds: CGRect
  ) {
    context.fill(
      body,
      with: .linearGradient(
        Gradient(colors: [look.tint(0.22), look.color, look.tint(-0.16)]),
        startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
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
  }

  /// Light from the top left with a soft highlight, from -1 in shadow to 1 fully lit.
  private func light(at point: CGPoint, in bounds: CGRect) -> Double {
    let across = (point.x - bounds.minX) / bounds.width
    let down = (point.y - bounds.minY) / bounds.height
    let falloff = (0.42 - (0.4 * across + 0.6 * down)) * 1.9
    let spot = max(0, 1 - hypot(across - 0.33, down - 0.22) / 0.26)
    return min(1, max(-1, falloff + 0.6 * spot))
  }

  /// A 4×4 ordered dither between the body color and a lighter and a darker step of it.
  private func paintDither(_ context: inout GraphicsContext, _ bounds: CGRect) {
    let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
    // Whole half points keep the squares on device pixels at 2x and sharp at 3x.
    let cell = max(0.5, (size / 44 * 2).rounded() / 2)
    let origin = CGPoint(x: (bounds.minX * 2).rounded(.down) / 2, y: (bounds.minY * 2).rounded(.down) / 2)
    var lit = Path()
    var shade = Path()
    for row in 0..<Int((bounds.maxY - origin.y) / cell + 1) {
      for column in 0..<Int((bounds.maxX - origin.x) / cell + 1) {
        let square = CGRect(
          x: origin.x + Double(column) * cell, y: origin.y + Double(row) * cell, width: cell, height: cell)
        let value = light(at: CGPoint(x: square.midX, y: square.midY), in: bounds)
        let threshold = (bayer[row % 4][column % 4] + 0.5) / 16
        if value > threshold {
          lit.addRect(square)
        } else if -value > threshold {
          shade.addRect(square)
        }
      }
    }
    context.fill(lit, with: .color(look.tint(0.3)))
    context.fill(shade, with: .color(look.tint(-0.24)))
  }

  /// Print-style dots on a staggered grid, growing toward the light and the shadow.
  private func paintHalftone(_ context: inout GraphicsContext, _ bounds: CGRect) {
    let cell = size / 20
    var lit = Path()
    var shade = Path()
    for row in 0...Int((bounds.height / cell).rounded(.up)) {
      let stagger = row.isMultiple(of: 2) ? 0 : cell / 2
      for column in 0...Int((bounds.width / cell).rounded(.up)) {
        let center = CGPoint(
          x: bounds.minX + Double(column) * cell + stagger, y: bounds.minY + Double(row) * cell)
        let value = light(at: center, in: bounds)
        let radius = cell * 0.62 * sqrt(abs(value))
        guard radius > cell * 0.08 else { continue }
        let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        if value > 0 { lit.addEllipse(in: dot) } else { shade.addEllipse(in: dot) }
      }
    }
    context.fill(lit, with: .color(look.tint(0.32)))
    context.fill(shade, with: .color(look.tint(-0.22)))
  }

  /// Seeded speckles, lighter ones toward the light and darker ones toward the shadow.
  private func paintGrain(_ context: inout GraphicsContext, _ bounds: CGRect) {
    var random = BotRandom(seed: look.hash)
    let speck = max(0.5, size / 90)
    let count = Int(bounds.width * bounds.height / (speck * speck) * 0.22)
    var lit = Path()
    var shade = Path()
    for _ in 0..<count {
      let point = CGPoint(
        x: bounds.minX + random.next() * bounds.width, y: bounds.minY + random.next() * bounds.height)
      let square = CGRect(x: point.x, y: point.y, width: speck, height: speck)
      if random.next() < 0.5 + 0.5 * light(at: point, in: bounds) {
        lit.addRect(square)
      } else {
        shade.addRect(square)
      }
    }
    context.fill(lit, with: .color(look.tint(0.35).opacity(0.45)))
    context.fill(shade, with: .color(look.tint(-0.35).opacity(0.4)))
  }
}

/// SplitMix64, so a bot's grain is the same every time it is drawn.
struct BotRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / Double(1 << 53)
  }
}
