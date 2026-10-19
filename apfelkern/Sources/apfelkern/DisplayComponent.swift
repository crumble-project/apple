import Foundation

/// An inline visual a bot shows with its `show` tool, decoded from the validated tool result.
public enum DisplayComponent: Decodable, Hashable, Sendable {
  case stats(title: String?, items: [Stat])
  case table(title: String?, columns: [String], rows: [[Cell]])
  case chart(Chart)

  public static let toolName = "show"

  public struct Stat: Decodable, Hashable, Sendable {
    public var label: String
    public var value: String
    public var change: String?
    public var trend: Trend?
    public var caption: String?
  }

  public enum Trend: String, Decodable, Hashable, Sendable {
    case up, down, flat
  }

  public enum Cell: Decodable, Hashable, Sendable {
    case text(String)
    case number(Double)

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(Double.self) {
        self = .number(value)
      } else {
        self = .text(try container.decode(String.self))
      }
    }

    public var text: String {
      switch self {
      case .text(let text): text
      case .number(let value): value.formatted()
      }
    }
  }

  public struct Chart: Decodable, Hashable, Sendable {
    public enum Style: String, Decodable, Hashable, Sendable {
      case bar, line
    }

    public struct Series: Decodable, Hashable, Sendable {
      public var name: String
      public var values: [Double]
    }

    public var title: String?
    public var chart: Style
    public var unit: String?
    public var labels: [String]
    public var series: [Series]
  }

  private enum CodingKeys: String, CodingKey {
    case kind, title, items, columns, rows
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let title = try container.decodeIfPresent(String.self, forKey: .title)
    switch try container.decode(String.self, forKey: .kind) {
    case "stats":
      self = .stats(title: title, items: try container.decode([Stat].self, forKey: .items))
    case "table":
      self = .table(
        title: title,
        columns: try container.decode([String].self, forKey: .columns),
        rows: try container.decode([[Cell]].self, forKey: .rows))
    case "chart":
      self = .chart(try Chart(from: decoder))
    case let kind:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "Unknown display component \(kind)")
    }
  }

  /// The component a successful `show` tool result carries; nil for other messages and unknown kinds.
  public init?(message: Message) {
    guard message.role == "toolResult", message.toolName == Self.toolName, message.isError != true,
      let details = message.toolDetails,
      let data = try? JSONEncoder().encode(details),
      let component = try? JSONDecoder().decode(Self.self, from: data)
    else { return nil }
    self = component
  }
}
