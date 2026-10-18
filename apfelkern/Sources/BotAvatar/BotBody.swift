import SwiftUI

struct BotBody: Shape {
  let shape: BotShape

  func path(in rect: CGRect) -> Path {
    let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
    switch shape {
    case .circle:
      return Path(ellipseIn: inset)
    case .squircle:
      return Path(roundedRect: inset, cornerRadius: rect.width * 0.28, style: .continuous)
    case .pill:
      let pill = CGRect(
        x: inset.minX, y: rect.midY - rect.height * 0.27, width: inset.width, height: rect.height * 0.54)
      return Path(roundedRect: pill, cornerRadius: pill.height / 2)
    case .triangle:
      var path = Path()
      path.move(to: CGPoint(x: rect.midX, y: inset.minY))
      path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
      path.closeSubpath()
      return path
    case .hexagon:
      var path = Path()
      path.addLines([
        CGPoint(x: rect.midX, y: inset.minY), CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.3),
        CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.7), CGPoint(x: rect.midX, y: inset.maxY),
        CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.7),
        CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.3)
      ])
      path.closeSubpath()
      return path
    case .cloud:
      return cloudPath(in: rect)
    case .drop:
      return dropPath(in: rect, inset: inset)
    }
  }

  /// Three puffs merged into one outline, so strokes and shading never show the seams.
  private func cloudPath(in rect: CGRect) -> Path {
    let puffs = [(0.08, 0.38, 0.48, 0.48), (0.28, 0.12, 0.5, 0.64), (0.55, 0.35, 0.38, 0.45)]
    let paths = puffs.map { left, top, width, height in
      Path(
        ellipseIn: CGRect(
          x: rect.minX + rect.width * left, y: rect.minY + rect.height * top, width: rect.width * width,
          height: rect.height * height))
    }
    return paths.dropFirst().reduce(paths[0]) { $0.union($1) }
  }

  private func dropPath(in rect: CGRect, inset: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: inset.minY))
    path.addCurve(
      to: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.62),
      control1: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.2),
      control2: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.42))
    path.addCurve(
      to: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.62),
      control1: CGPoint(x: inset.maxX, y: inset.maxY), control2: CGPoint(x: inset.minX, y: inset.maxY))
    path.addCurve(
      to: CGPoint(x: rect.midX, y: inset.minY),
      control1: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.42),
      control2: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.2))
    return path
  }
}
