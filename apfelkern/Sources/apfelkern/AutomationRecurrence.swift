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

/// A five-field cron expression for the next-run preview: lists, ranges, steps, and month and weekday names.
/// The server takes more than this, so nil means "can't say", not "invalid".
public struct CronExpression: Sendable {
  private let minutes: [Int]
  private let hours: [Int]
  private let days: Set<Int>
  private let months: Set<Int>
  private let weekdays: Set<Int>
  private let dayIsAny: Bool
  private let weekdayIsAny: Bool

  private static let monthNames = [
    "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
    "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12
  ]
  private static let dayNames = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]
  /// The longest wait a matching date can need: February 29 across a skipped leap year.
  private static let searchedDays = 366 * 9

  public init?(_ text: String) {
    let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 5,
      let minutes = Self.values(fields[0], 0...59),
      let hours = Self.values(fields[1], 0...23),
      let days = Self.values(fields[2], 1...31),
      let months = Self.values(fields[3], 1...12, names: Self.monthNames),
      let weekdays = Self.values(fields[4], 0...7, names: Self.dayNames)
    else { return nil }
    self.minutes = minutes.sorted()
    self.hours = hours.sorted()
    self.days = days
    self.months = months
    self.weekdays = Set(weekdays.map { $0 % 7 })
    dayIsAny = days.count == 31
    weekdayIsAny = Set(weekdays.map { $0 % 7 }).count == 7
  }

  private static func values(
    _ field: String, _ range: ClosedRange<Int>, names: [String: Int] = [:]
  ) -> Set<Int>? {
    var values = Set<Int>()
    for part in field.split(separator: ",", omittingEmptySubsequences: false) {
      let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
      guard pieces.count <= 2 else { return nil }
      let step = pieces.count == 2 ? Int(pieces[1]) : 1
      guard let step, step > 0, let bounds = bounds(String(pieces[0]), range, names, stepped: pieces.count == 2)
      else { return nil }
      values.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
    }
    return values.isEmpty ? nil : values
  }

  private static func bounds(
    _ text: String, _ range: ClosedRange<Int>, _ names: [String: Int], stepped: Bool
  ) -> ClosedRange<Int>? {
    if text == "*" || text == "?" { return range }
    let value = { (part: Substring) -> Int? in
      let number = names[part.uppercased()] ?? Int(part)
      return number.flatMap { range.contains($0) ? $0 : nil }
    }
    let ends = text.split(separator: "-", omittingEmptySubsequences: false)
    if ends.count == 2 {
      guard let low = value(ends[0]), let high = value(ends[1]), low <= high else { return nil }
      return low...high
    }
    guard ends.count == 1, let start = value(ends[0]) else { return nil }
    return stepped ? start...range.upperBound : start...start
  }

  /// The first run after a moment, or nil if the date never comes, like February 31.
  public func next(after date: Date, in zone: TimeZone) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let start = calendar.startOfDay(for: date)
    for offset in 0..<Self.searchedDays {
      guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
      let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
      guard matches(parts) else { continue }
      if let run = firstTime(on: parts, after: date, calendar: calendar) { return run }
    }
    return nil
  }

  private func matches(_ parts: DateComponents) -> Bool {
    guard let month = parts.month, let day = parts.day, let weekday = parts.weekday, months.contains(month)
    else { return false }
    let (onDay, onWeekday) = (days.contains(day), weekdays.contains(weekday - 1))
    // Cron's rule: when both are set, either one matching is enough.
    return dayIsAny || weekdayIsAny ? onDay && onWeekday : onDay || onWeekday
  }

  private func firstTime(on parts: DateComponents, after date: Date, calendar: Calendar) -> Date? {
    for hour in hours {
      for minute in minutes {
        var moment = parts
        moment.weekday = nil
        moment.hour = hour
        moment.minute = minute
        guard let run = calendar.date(from: moment), run > date,
          // A time a clock change skips doesn't exist that day.
          calendar.component(.hour, from: run) == hour, calendar.component(.minute, from: run) == minute
        else { continue }
        return run
      }
    }
    return nil
  }
}
