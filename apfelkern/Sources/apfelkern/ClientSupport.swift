import Foundation

/// Unions transcript rows by ID in entry order. Entries are immutable, so a row that scrolled
/// out of the newest snapshot page stays valid.
public func mergeMessages(_ existing: [Message], _ incoming: [Message]) -> [Message] {
  var byID: [String: Message] = [:]
  for message in existing + incoming { byID[message.id] = message }
  return byID.values.sorted { messageOrder($0.id).lexicographicallyPrecedes(messageOrder($1.id)) }
}

/// Reads the entry and message index from an "agent:entry:index" row ID.
public func messageOrder(_ id: String) -> [Int] {
  let parts = id.split(separator: ":", omittingEmptySubsequences: false)
  guard parts.count >= 2 else { return [0, 0] }
  return [Int(parts[parts.count - 2]) ?? 0, Int(parts[parts.count - 1]) ?? 0]
}

public func newRequestID() -> String { UUID().uuidString.lowercased() }

public struct SignInError: LocalizedError {
  public var errorDescription: String?

  public init(
    errorDescription: String? = nil
  ) {
    self.errorDescription = errorDescription
  }
}

/// Reads the code, state and issuer from a sign-in callback, or the provider's reason for refusing.
public struct OAuthResult {
  public let code: String
  public let state: String
  public let iss: String?

  public init(
    code: String,
    state: String,
    iss: String? = nil
  ) {
    self.code = code
    self.state = state
    self.iss = iss
  }
}

public func oauthResult(from callback: URL) throws -> OAuthResult {
  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
  let value = { (name: String) in items.first { $0.name == name }?.value }
  if let error = value("error") {
    throw SignInError(
      errorDescription: "Sign-in was refused: " + (value("error_description") ?? error))
  }
  guard let code = value("code"), let state = value("state") else {
    throw SignInError(errorDescription: "Sign-in returned no authorization code.")
  }
  return OAuthResult(code: code, state: state, iss: value("iss"))
}

/// Server timestamps are absolute instants; the date picker displays them in its time zone.
public func automationRunDate(_ value: String) -> Date? {
  let parser = ISO8601DateFormatter()
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = parser.date(from: value) { return date }
  parser.formatOptions = [.withInternetDateTime]
  return parser.date(from: value)
}

public func friendlyError(_ error: Error) -> String {
  if let apiError = error as? APIError {
    if apiError.statusCode == 401 {
      return "Your session has ended. Sign in again in Settings."
    }
    struct Body: Decodable {
      struct Detail: Decodable { var message: String? }
      var error: String?
      var details: [Detail]?
    }
    if let body = try? JSONDecoder().decode(Body.self, from: Data(apiError.body.utf8)),
      let message = body.error, !message.isEmpty {
      if let detail = body.details?.first?.message { return message + ": " + detail }
      return message
    }
  }
  return error.localizedDescription
}

public func timeLabel(_ date: Date, now: Date = .now) -> String {
  let calendar = Calendar.current
  let time = date.formatted(date: .omitted, time: .shortened)
  if calendar.isDate(date, inSameDayAs: now) { return "Today " + time }
  if calendar.isDate(date, equalTo: now, toGranularity: .year) {
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + time
  }
  return date.formatted(date: .abbreviated, time: .shortened)
}

public func activityTime(_ value: String?) -> String {
  guard let value else { return "" }
  let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  guard let date = (try? fractional.parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value))
  else { return value }
  return timeLabel(date)
}

public func activityTime(_ value: Int64?) -> String {
  guard let value else { return "" }
  return timeLabel(Date(timeIntervalSince1970: Double(value) / 1000))
}

public extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }

  var trimmingTrailingSlashes: String {
    var value = self
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }
}

/// How long ago, in the largest unit that fits, as the web's `agoInLargestUnit`.
public func ageLabel(_ date: Date, now: Date = .now) -> String {
  let steps: [(Double, (Int) -> DateComponents)] = [
    (60, { DateComponents(minute: $0) }), (60, { DateComponents(hour: $0) }), (24, { DateComponents(day: $0) }),
    (7, { DateComponents(weekOfMonth: $0) }), (4.35, { DateComponents(month: $0) }), (12, { DateComponents(year: $0) })
  ]
  var value = date.timeIntervalSince(now)
  var components = DateComponents(minute: 0)
  for (size, unit) in steps {
    if abs(value) < size { break }
    value /= size
    components = unit(Int(value.rounded()))
  }
  let formatter = RelativeDateTimeFormatter()
  formatter.dateTimeStyle = .named
  return formatter.localizedString(from: components)
}

/// The line under a memory: where it came from and how long ago it changed.
public func memoryLine(_ memory: Memory, now: Date = .now) -> String? {
  let age = memory.updatedAt.flatMap(automationRunDate).map { ageLabel($0, now: now) }
  return [memorySourceLabel(memory.source), age].compactMap(\.self).joined(separator: " · ").nilIfEmpty
}

public func memorySourceSymbol(_ source: MemorySource?) -> String? {
  switch source?.kind {
  case "chat": "message"
  case "owner": "person"
  case "task": "calendar.badge.clock"
  case "bot": "cpu"
  case "group": "person.2"
  default: nil
  }
}

/// Every case-insensitive match of a trimmed search in `text`, without overlaps.
public func searchMatches(of query: String, in text: String) -> [Range<String.Index>] {
  let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !needle.isEmpty else { return [] }
  var matches: [Range<String.Index>] = []
  var start = text.startIndex
  while let match = text.range(of: needle, options: .caseInsensitive, range: start..<text.endIndex, locale: .current) {
    matches.append(match)
    start = match.upperBound
  }
  return matches
}

/// Where a memory was saved, for the line under it; nil for memories saved before sources were recorded.
public func memorySourceLabel(_ source: MemorySource?) -> String? {
  guard let source else { return nil }
  let name = source.name?.nilIfEmpty
  switch source.kind {
  case "chat": return "From the bot chat"
  case "owner": return "Added by you"
  case "task": return name.map { "From the automation \($0)" } ?? "From an automation"
  case "bot": return name.map { "From a request by \($0)" } ?? "From another bot"
  case "group": return name.map { "From the group chat \($0)" } ?? "From a group chat"
  default: return nil
  }
}
