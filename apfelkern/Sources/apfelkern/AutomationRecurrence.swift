import Foundation

/// The repeating schedules the builder offers, each one cron shape.
public struct Recurrence: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case hourly, daily, weekdays, weekly, monthly
  }

  public var kind: Kind
  public var minute: Int
  public var hour = 9
  /// Cron weekdays: Sunday is 0.
  public var days = [1]
  /// The day of the month.
  public var day = 1

  public init(kind: Kind, minute: Int = 0, hour: Int = 9, days: [Int] = [1], day: Int = 1) {
    self.kind = kind
    self.minute = minute
    self.hour = hour
    self.days = days
    self.day = day
  }

  /// Nil for any cron the builder can't show, which then stays custom.
  public init?(cron: String) {
    let fields = cron.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 5, let minute = Self.number(fields[0]), minute <= 59 else { return nil }
    if Array(fields[1...]) == ["*", "*", "*", "*"] {
      self.init(kind: .hourly, minute: minute)
      return
    }
    guard let hour = Self.number(fields[1]), hour <= 23, fields[3] == "*" else { return nil }
    guard let shape = Self.dayShape(dayOfMonth: fields[2], weekday: fields[4]) else { return nil }
    self.init(kind: shape.kind, minute: minute, hour: hour, days: shape.days, day: shape.day)
  }

  private static func dayShape(dayOfMonth: String, weekday: String) -> Recurrence? {
    switch (dayOfMonth, weekday) {
    case ("*", "*"): return Recurrence(kind: .daily)
    case ("*", "1-5"): return Recurrence(kind: .weekdays)
    case ("*", _):
      let days = weekday.split(separator: ",", omittingEmptySubsequences: false).map { number(String($0)) }
      guard days.allSatisfy({ $0.map { $0 <= 7 } ?? false }) else { return nil }
      var unique: [Int] = []
      for day in days.compactMap(\.self) where !unique.contains(day % 7) { unique.append(day % 7) }
      return Recurrence(kind: .weekly, days: unique)
    case (_, "*"):
      guard let day = number(dayOfMonth), (1...31).contains(day) else { return nil }
      return Recurrence(kind: .monthly, day: day)
    default: return nil
    }
  }

  private static func number(_ text: String) -> Int? {
    text.isEmpty || !text.allSatisfy(\.isASCII) || !text.allSatisfy(\.isNumber) ? nil : Int(text)
  }

  public var cron: String {
    switch kind {
    case .hourly: "\(minute) * * * *"
    case .daily: "\(minute) \(hour) * * *"
    case .weekdays: "\(minute) \(hour) * * 1-5"
    case .weekly: "\(minute) \(hour) * * \(days.sorted().map(String.init).joined(separator: ","))"
    case .monthly: "\(minute) \(hour) \(day) * *"
    }
  }

  /// The same schedule as another kind, keeping the settings that carry over.
  public func switched(to kind: Kind) -> Recurrence {
    var next = self
    next.kind = kind
    return next
  }

  /// A wall-clock time on a fixed day, for a time picker in the automation's zone.
  public func time(in zone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2023, month: 1, day: 1, hour: hour, minute: minute)) ?? .now
  }

  public mutating func setTime(_ date: Date, in zone: TimeZone) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    hour = calendar.component(.hour, from: date)
    minute = calendar.component(.minute, from: date)
  }

  /// Toggles a weekday, keeping at least one.
  public mutating func toggle(weekday: Int) {
    if days.contains(weekday) {
      if days.count > 1 { days.removeAll { $0 == weekday } }
    } else {
      days.append(weekday)
    }
  }

  /// Monday first, as the week reads; cron counts Sunday as 0.
  public static let week = [1, 2, 3, 4, 5, 6, 0]
}

/// What the When picker offers.
public enum AutomationWhen: String, CaseIterable, Identifiable, Sendable {
  case once, hourly, daily, weekdays, weekly, monthly, custom

  public var id: Self { self }

  public var label: String {
    switch self {
    case .once: "Once"
    case .hourly: "Every hour"
    case .daily: "Every day"
    case .weekdays: "Every weekday"
    case .weekly: "Every week"
    case .monthly: "Every month"
    case .custom: "Custom (cron)"
    }
  }

  var recurrenceKind: Recurrence.Kind? { Recurrence.Kind(rawValue: rawValue) }
}
