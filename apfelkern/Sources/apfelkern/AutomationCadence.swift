import Foundation

/// When an automation runs: its event source, its cron shape in words, or its one time.
public func cadence(_ schedule: Schedule, sources: [EventSource] = [], now: Date = .now) -> String {
  if let sourceID = schedule.eventSourceId {
    return sources.first { $0.id == sourceID }.map { "On event · \($0.name)" } ?? "On event"
  }
  guard let cron = schedule.cron?.nilIfEmpty else {
    guard let runAt = schedule.runAt, let date = automationRunDate(runAt) else { return "Once" }
    let zone = schedule.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    let when = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
    return date < now && schedule.nextRunAt == nil ? "Ran \(when)" : "Once, \(when)"
  }
  return cronPhrase(cron, timezone: schedule.timezone)
}

/// An automation's timing beside its switch, where a paused one says so.
public func automationTiming(_ schedule: Schedule, sources: [EventSource] = []) -> String {
  (schedule.enabled ? "" : "Paused · ") + cadence(schedule, sources: sources)
}

/// A cron expression in words for the shapes people use, or the expression itself.
public func cronPhrase(_ cron: String, timezone: String?) -> String {
  let text = cron.trimmingCharacters(in: .whitespacesAndNewlines)
  // Cron times are in the automation's own zone; name it when that isn't this device's.
  let zone = timezone?.nilIfEmpty.flatMap { $0 == TimeZone.current.identifier ? nil : " (\($0))" } ?? ""
  let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
  if fields.count == 5, fields[0].hasPrefix("*/"), Array(fields[1...]) == ["*", "*", "*", "*"] {
    return "Every \(fields[0].dropFirst(2)) minutes"
  }
  let named = ["MON-FRI": "1-5", "SAT,SUN": "0,6"]
  let spelled = fields.count == 5 ? (fields[..<4] + [named[fields[4]] ?? fields[4]]).joined(separator: " ") : text
  guard let recurrence = Recurrence(cron: spelled) else { return text + zone }
  if recurrence.kind == .hourly { return "Every hour at :" + String(format: "%02d", recurrence.minute) }
  return recurrence.phrase + zone
}

extension Recurrence {
  fileprivate var phrase: String {
    let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute))?
      .formatted(date: .omitted, time: .shortened) ?? ""
    switch kind {
    case .hourly: return "Every hour at :" + String(format: "%02d", minute)
    case .daily: return "Every day at \(time)"
    case .weekdays: return "Weekdays at \(time)"
    case .monthly: return "Every month on day \(day) at \(time)"
    case .weekly:
      if Set(days) == [0, 6] { return "Weekends at \(time)" }
      if let only = days.first, days.count == 1 { return "Every \(Calendar.current.weekdaySymbols[only]) at \(time)" }
      let names = days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { Calendar.current.shortWeekdaySymbols[$0] }
      return names.joined(separator: ", ") + " at \(time)"
    }
  }
}

/// A run's day in the automation's zone, as "today at 09:00".
public func humanRun(_ date: Date, zone: TimeZone, now: Date = .now) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  let days = calendar.dateComponents(
    [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
  let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
  let day: String
  switch days {
  case 0: day = "today"
  case 1: day = "tomorrow"
  case 2..<7: day = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide))
  default: day = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).day().month(.abbreviated))
  }
  return "\(day) at \(time)"
}
