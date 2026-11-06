import apfelkern
import Foundation
import SwiftUI

/// A brand's mark, as the web shows it. Falls back to a letter or a symbol for what has no logo.
public enum BrandLogo: Hashable, Sendable {
  case provider(id: String, name: String)
  case passwordManager(PasswordManagerID)
  case gateway(String)

  var key: String {
    switch self {
    case .provider(let id, _): "provider:\(id)"
    case .passwordManager(let id): "manager:\(id.rawValue)"
    case .gateway(let id): "gateway:\(id)"
    }
  }
}

public struct BrandLogoView: View {
  let logo: BrandLogo
  let size: CGFloat

  public init(_ logo: BrandLogo, size: CGFloat = 20) {
    self.logo = logo
    self.size = size
  }

  public var body: some View {
    Group {
      if let artwork = BrandArtwork.all[logo.key] {
        Canvas { context, canvas in artwork.draw(in: &context, size: canvas) }
      } else if case .provider(_, let name) = logo {
        Text(name.prefix(1).uppercased()).font(.system(size: size * 0.7, weight: .semibold))
      } else {
        Image(systemName: "message").resizable().scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A logo's SVG, parsed. The bundled marks only use paths and linear gradients in user space.
struct BrandArtwork: Sendable {
  enum Fill: Sendable {
    case foreground
    case color(Color)
    case gradient(String)
  }

  struct Layer: Sendable {
    var path: Path
    var fill: Fill
    var evenOdd: Bool
  }

  struct LinearGradient: Sendable {
    var start: CGPoint
    var end: CGPoint
    var stops: [Gradient.Stop]
  }

  var box: CGSize
  var layers: [Layer] = []
  var gradients: [String: LinearGradient] = [:]

  static let all = BrandLogoData.markup.compactMapValues(BrandArtwork.init(svg:))

  init?(svg: String) {
    let reader = SVGReader()
    let parser = XMLParser(data: Data(svg.utf8))
    parser.delegate = reader
    guard parser.parse(), !reader.artwork.layers.isEmpty else { return nil }
    self = reader.artwork
  }

  init(box: CGSize) {
    self.box = box
  }

  func draw(in context: inout GraphicsContext, size: CGSize) {
    context.scaleBy(x: size.width / box.width, y: size.height / box.height)
    for layer in layers {
      context.fill(layer.path, with: shading(layer.fill), style: FillStyle(eoFill: layer.evenOdd))
    }
  }

  private func shading(_ fill: Fill) -> GraphicsContext.Shading {
    switch fill {
    case .foreground: return .foreground
    case .color(let color): return .color(color)
    case .gradient(let id):
      guard let gradient = gradients[id] else { return .foreground }
      return .linearGradient(
        Gradient(stops: gradient.stops), startPoint: gradient.start, endPoint: gradient.end)
    }
  }
}

private final class SVGReader: NSObject, XMLParserDelegate {
  var artwork = BrandArtwork(box: CGSize(width: 24, height: 24))
  private var rootFill: BrandArtwork.Fill = .foreground
  private var rootEvenOdd = false
  private var gradient: (id: String, value: BrandArtwork.LinearGradient)?

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    switch name {
    case "svg":
      if let numbers = attributes["viewBox"]?.split(separator: " ").compactMap({ Double($0) }), numbers.count == 4 {
        artwork.box = CGSize(width: numbers[2], height: numbers[3])
      }
      rootFill = Self.fill(attributes["fill"]) ?? .foreground
      rootEvenOdd = attributes["fill-rule"] == "evenodd"
    case "path":
      guard let data = attributes["d"] else { return }
      artwork.layers.append(BrandArtwork.Layer(
        path: svgPath(data), fill: Self.fill(attributes["fill"]) ?? rootFill,
        evenOdd: attributes["fill-rule"].map { $0 == "evenodd" } ?? rootEvenOdd))
    case "linearGradient":
      guard let id = attributes["id"] else { return }
      gradient = (id, BrandArtwork.LinearGradient(
        start: CGPoint(x: Self.number(attributes["x1"]), y: Self.number(attributes["y1"])),
        end: CGPoint(x: Self.number(attributes["x2"]), y: Self.number(attributes["y2"])), stops: []))
    case "stop":
      let opacity = attributes["stop-opacity"].flatMap(Double.init) ?? 1
      let color = Self.color(attributes["stop-color"] ?? "#000")?.opacity(opacity) ?? .clear
      gradient?.value.stops.append(Gradient.Stop(color: color, location: Self.number(attributes["offset"])))
    default: break
    }
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    guard name == "linearGradient", let gradient else { return }
    artwork.gradients[gradient.id] = gradient.value
    self.gradient = nil
  }

  private static func number(_ text: String?) -> Double { text.flatMap(Double.init) ?? 0 }

  private static func fill(_ text: String?) -> BrandArtwork.Fill? {
    guard let text else { return nil }
    if text == "currentColor" { return .foreground }
    if text.hasPrefix("url(#") { return .gradient(String(text.dropFirst(5).dropLast())) }
    return color(text).map(BrandArtwork.Fill.color)
  }

  private static func color(_ text: String) -> Color? {
    var digits = text.dropFirst()
    guard text.hasPrefix("#") else { return nil }
    if digits.count == 3 { digits = Substring(digits.map { "\($0)\($0)" }.joined()) }
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    return Color(
      red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}
