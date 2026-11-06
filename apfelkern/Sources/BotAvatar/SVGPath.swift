// swiftlint:disable identifier_name
import Foundation
import SwiftUI

/// Builds a path from SVG path data, including the compact forms icon optimizers write, such as
/// `a5 5 0 015-5`, where arc flags and numbers run together.
func svgPath(_ data: String) -> Path {
  var scanner = SVGPathScanner(data)
  var builder = SVGPathBuilder()
  var command: UInt8 = 0
  while let next = scanner.next(previous: command) {
    command = next
    guard builder.apply(command, &scanner) else { break }
    // After a moveto, further coordinate pairs are linetos.
    if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
    if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
  }
  return builder.path
}

private struct SVGPathScanner {
  private let bytes: [UInt8]
  private var index = 0

  init(_ text: String) {
    bytes = Array(text.utf8)
  }

  private mutating func skipSeparators() {
    while index < bytes.count, [0x20, 0x2C, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }

  /// A letter here, or the last command repeating for more numbers.
  mutating func next(previous: UInt8) -> UInt8? {
    skipSeparators()
    guard index < bytes.count else { return nil }
    let byte = bytes[index]
    if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
      index += 1
      return byte
    }
    return previous == 0 ? nil : previous
  }

  mutating func number() -> CGFloat? {
    skipSeparators()
    let start = index
    if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
    var seenDot = false
    while index < bytes.count {
      let byte = bytes[index]
      if byte >= 0x30, byte <= 0x39 {
        index += 1
      } else if byte == 0x2E, !seenDot {
        seenDot = true
        index += 1
      } else if byte == 0x65 || byte == 0x45 {
        index += 1
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
      } else {
        break
      }
    }
    guard index > start else { return nil }
    return String(bytes: bytes[start..<index], encoding: .utf8).flatMap(Double.init).map { CGFloat($0) }
  }

  /// One digit, with or without a separator after it.
  mutating func flag() -> Bool? {
    skipSeparators()
    guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
    index += 1
    return bytes[index - 1] == 0x31
  }
}

private struct SVGPathBuilder {
  var path = Path()
  private var current = CGPoint.zero
  private var start = CGPoint.zero
  /// The last curve's control point and whether it was cubic, which `S` and `T` reflect.
  private var control: (point: CGPoint, cubic: Bool)?

  private func point(_ scanner: inout SVGPathScanner, relative: Bool) -> CGPoint? {
    guard let x = scanner.number(), let y = scanner.number() else { return nil }
    return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
  }

  private func reflected(cubic: Bool) -> CGPoint {
    guard let control, control.cubic == cubic else { return current }
    return CGPoint(x: 2 * current.x - control.point.x, y: 2 * current.y - control.point.y)
  }

  mutating func apply(_ command: UInt8, _ scanner: inout SVGPathScanner) -> Bool {
    let relative = command >= 0x61
    switch command | 0x20 {
    case UInt8(ascii: "z"):
      path.closeSubpath()
      current = start
      control = nil
      return true
    case UInt8(ascii: "m"):
      guard let to = point(&scanner, relative: relative) else { return false }
      path.move(to: to)
      start = to
      current = to
      control = nil
      return true
    case UInt8(ascii: "l"):
      guard let to = point(&scanner, relative: relative) else { return false }
      line(to)
      return true
    case UInt8(ascii: "h"):
      guard let x = scanner.number() else { return false }
      line(CGPoint(x: relative ? current.x + x : x, y: current.y))
      return true
    case UInt8(ascii: "v"):
      guard let y = scanner.number() else { return false }
      line(CGPoint(x: current.x, y: relative ? current.y + y : y))
      return true
    case UInt8(ascii: "a"): return arc(&scanner, relative: relative)
    default: return curve(command, &scanner, relative: relative)
    }
  }

  private mutating func line(_ to: CGPoint) {
    path.addLine(to: to)
    current = to
    control = nil
  }

  private mutating func curve(_ command: UInt8, _ scanner: inout SVGPathScanner, relative: Bool) -> Bool {
    switch command | 0x20 {
    case UInt8(ascii: "c"):
      guard let first = point(&scanner, relative: relative), let second = point(&scanner, relative: relative),
        let to = point(&scanner, relative: relative) else { return false }
      cubic(first, second, to)
    case UInt8(ascii: "s"):
      let first = reflected(cubic: true)
      guard let second = point(&scanner, relative: relative), let to = point(&scanner, relative: relative)
      else { return false }
      cubic(first, second, to)
    case UInt8(ascii: "q"):
      guard let middle = point(&scanner, relative: relative), let to = point(&scanner, relative: relative)
      else { return false }
      quadratic(middle, to)
    case UInt8(ascii: "t"):
      let middle = reflected(cubic: false)
      guard let to = point(&scanner, relative: relative) else { return false }
      quadratic(middle, to)
    default: return false
    }
    return true
  }

  private mutating func cubic(_ first: CGPoint, _ second: CGPoint, _ to: CGPoint) {
    path.addCurve(to: to, control1: first, control2: second)
    current = to
    control = (second, true)
  }

  private mutating func quadratic(_ middle: CGPoint, _ to: CGPoint) {
    path.addQuadCurve(to: to, control: middle)
    current = to
    control = (middle, false)
  }

  /// SVG's implementation notes, F.6: endpoints to center, then one cubic per quarter turn at most.
  private mutating func arc(_ scanner: inout SVGPathScanner, relative: Bool) -> Bool {
    guard var rx = scanner.number().map(abs), var ry = scanner.number().map(abs),
      let degrees = scanner.number(), let large = scanner.flag(), let sweep = scanner.flag(),
      let to = point(&scanner, relative: relative) else { return false }
    defer {
      current = to
      control = nil
    }
    guard rx > 0, ry > 0, to != current else {
      path.addLine(to: to)
      return true
    }
    let angle = degrees * .pi / 180
    let (cosine, sine) = (cos(angle), sin(angle))
    let (dx, dy) = ((current.x - to.x) / 2, (current.y - to.y) / 2)
    let px = cosine * dx + sine * dy
    let py = cosine * dy - sine * dx
    let scale = (px * px) / (rx * rx) + (py * py) / (ry * ry)
    if scale > 1 {
      rx *= scale.squareRoot()
      ry *= scale.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px
    let denominator = rx * rx * py * py + ry * ry * px * px
    let factor = (large == sweep ? -1 : 1) * (max(0, numerator) / denominator).squareRoot()
    let (ucx, ucy) = (factor * rx * py / ry, -factor * ry * px / rx)
    let center = CGPoint(
      x: cosine * ucx - sine * ucy + (current.x + to.x) / 2,
      y: sine * ucx + cosine * ucy + (current.y + to.y) / 2)
    let startAngle = atan2((py - ucy) / ry, (px - ucx) / rx)
    var turn = atan2((-py - ucy) / ry, (-px - ucx) / rx) - startAngle
    if sweep, turn < 0 { turn += 2 * .pi }
    if !sweep, turn > 0 { turn -= 2 * .pi }
    let segments = max(1, Int((abs(turn) / (.pi / 2)).rounded(.up)))
    let step = turn / CGFloat(segments)
    let handle = 4.0 / 3.0 * tan(step / 4)
    func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(
        x: center.x + cosine * rx * x - sine * ry * y,
        y: center.y + sine * rx * x + cosine * ry * y)
    }
    for segment in 0..<segments {
      let from = startAngle + CGFloat(segment) * step
      let until = from + step
      path.addCurve(
        to: segment == segments - 1 ? to : onEllipse(cos(until), sin(until)),
        control1: onEllipse(cos(from) - handle * sin(from), sin(from) + handle * cos(from)),
        control2: onEllipse(cos(until) + handle * sin(until), sin(until) - handle * cos(until)))
    }
    return true
  }
}
