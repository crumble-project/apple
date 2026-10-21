import Foundation

/// One compiled chart at one width, in points: paint-ordered primitives with absolute coordinates, plus hover targets.
/// The bot server's `chartLayout` schema defines and validates this format.
public struct ChartLayout: Decodable, Hashable, Sendable {
  public var width: Double
  public var height: Double
  public var nodes: [ChartNode]
  public var points: [ChartPoint]
}

/// A theme token resolved per appearance (`foreground`, `background`, `series-1`…`series-8`), a hex literal, or `none`.
public enum ChartColor: Hashable, Sendable {
  case none
  case foreground
  case background
  case series(Int)
  /// Red, green, blue, and alpha in 0...1.
  case rgba(Double, Double, Double, Double)

  public init(_ value: String) {
    switch value {
    case "none": self = .none
    case "foreground": self = .foreground
    case "background": self = .background
    default:
      if value.hasPrefix("series-"), let index = Int(value.dropFirst(7)) {
        self = .series(index)
      } else {
        self = ChartColor.hex(value) ?? .none
      }
    }
  }

  private static func hex(_ value: String) -> ChartColor? {
    var digits = String(value.dropFirst())
    guard value.hasPrefix("#") else { return nil }
    if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
    guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
    let channels = digits.count == 8 ? number : number << 8 | 0xFF
    return .rgba(
      Double(channels >> 24 & 0xFF) / 255, Double(channels >> 16 & 0xFF) / 255,
      Double(channels >> 8 & 0xFF) / 255, Double(channels & 0xFF) / 255)
  }
}

extension ChartColor: Decodable {
  public init(from decoder: Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(String.self))
  }
}

public struct ChartPaint: Decodable, Hashable, Sendable {
  public var fill: ChartColor?
  public var fillOpacity: Double?
  public var stroke: ChartColor?
  public var strokeOpacity: Double?
  public var strokeWidth: Double?
  public var opacity: Double?
  public var lineCap: String?
  public var lineJoin: String?
  public var dash: [Double]?
  /// x, y, width, height.
  public var clip: [Double]?
}

public enum ChartPathCommand: Decodable, Hashable, Sendable {
  case move(Double, Double)
  case line(Double, Double)
  case quad(Double, Double, Double, Double)
  case curve(Double, Double, Double, Double, Double, Double)
  case close

  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let name = try container.decode(String.self)
    var values: [Double] = []
    while !container.isAtEnd { values.append(try container.decode(Double.self)) }
    switch (name, values.count) {
    case ("M", 2): self = .move(values[0], values[1])
    case ("L", 2): self = .line(values[0], values[1])
    case ("Q", 4): self = .quad(values[0], values[1], values[2], values[3])
    case ("C", 6): self = .curve(values[0], values[1], values[2], values[3], values[4], values[5])
    case ("Z", 0): self = .close
    default:
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unknown path command \(name) with \(values.count) values")
    }
  }
}

public enum ChartNode: Decodable, Hashable, Sendable {
  case line(x1: Double, y1: Double, x2: Double, y2: Double, paint: ChartPaint)
  case path(commands: [ChartPathCommand], evenOdd: Bool, paint: ChartPaint)
  case circle(x: Double, y: Double, radius: Double, paint: ChartPaint)
  case rect(x: Double, y: Double, width: Double, height: Double, radius: Double, paint: ChartPaint)
  case text(ChartText, paint: ChartPaint)
  /// A primitive this client does not draw yet; skipped, so newer servers stay readable.
  case unsupported

  private enum CodingKeys: String, CodingKey {
    case kind, x1, y1, x2, y2, commands, evenOdd, x, y, radius, width, height
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let paint = try ChartPaint(from: decoder)
    func number(_ key: CodingKeys) throws -> Double { try container.decode(Double.self, forKey: key) }
    switch try container.decode(String.self, forKey: .kind) {
    case "line":
      self = .line(x1: try number(.x1), y1: try number(.y1), x2: try number(.x2), y2: try number(.y2), paint: paint)
    case "path":
      self = .path(
        commands: try container.decode([ChartPathCommand].self, forKey: .commands),
        evenOdd: try container.decodeIfPresent(Bool.self, forKey: .evenOdd) ?? false, paint: paint)
    case "circle":
      self = .circle(x: try number(.x), y: try number(.y), radius: try number(.radius), paint: paint)
    case "rect":
      self = .rect(
        x: try number(.x), y: try number(.y), width: try number(.width), height: try number(.height),
        radius: try number(.radius), paint: paint)
    case "text":
      self = .text(try ChartText(from: decoder), paint: paint)
    default:
      self = .unsupported
    }
  }
}

public struct ChartText: Decodable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var text: String
  /// `start`, `middle`, or `end`.
  public var anchor: String
  /// `auto` (alphabetic), `middle`, or `hanging`.
  public var baseline: String
  /// Degrees, clockwise.
  public var rotate: Double
  public var size: Double
  public var weight: Double
}

/// A hover target with its finished tooltip.
public struct ChartPoint: Decodable, Hashable, Sendable {
  public struct Row: Decodable, Hashable, Sendable {
    public var label: String
    public var value: String
    public var color: ChartColor?
  }

  public var x: Double
  public var y: Double
  public var color: ChartColor?
  public var title: String?
  public var text: String?
  public var rows: [Row]
}

/// The categorical chart palette, validated for color-vision deficiency separately against light and dark surfaces.
public enum ChartPalette {
  private static let light: [UInt32] = [
    0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6, 0xe34948
  ]
  private static let dark: [UInt32] = [
    0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767
  ]

  /// The literal color for a one-based series slot; the server only sends slots one through eight.
  public static func series(_ slot: Int, dark: Bool) -> ChartColor {
    let colors = dark ? Self.dark : Self.light
    let value = colors[(max(slot, 1) - 1) % colors.count]
    return .rgba(Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
  }
}
