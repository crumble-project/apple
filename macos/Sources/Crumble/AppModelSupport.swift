import Foundation

// MARK: Helpers

/// Unions transcript rows by ID in entry order. Entries are immutable, so a row that scrolled
/// out of the newest snapshot page stays valid.
func mergeMessages(_ existing: [Message], _ incoming: [Message]) -> [Message] {
    var byID: [String: Message] = [:]
    for message in existing + incoming { byID[message.id] = message }
    return byID.values.sorted { messageOrder($0.id).lexicographicallyPrecedes(messageOrder($1.id)) }
}

/// Reads the entry and message index from an "agent:entry:index" row ID.
func messageOrder(_ id: String) -> [Int] {
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return [0, 0] }
    return [Int(parts[parts.count - 2]) ?? 0, Int(parts[parts.count - 1]) ?? 0]
}

func newRequestID() -> String { UUID().uuidString.lowercased() }

struct SignInError: LocalizedError {
    var errorDescription: String?
}

/// Reads the code, state and issuer from a sign-in callback, or the provider's reason for refusing.
struct MCPOAuthResult {
    let code: String
    let state: String
    let iss: String?
}

func oauthResult(from callback: URL) throws -> MCPOAuthResult {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value = { (name: String) in items.first { $0.name == name }?.value }
    if let error = value("error") {
        throw SignInError(errorDescription: "Sign-in was refused: " + (value("error_description") ?? error))
    }
    guard let code = value("code"), let state = value("state") else {
        throw SignInError(errorDescription: "Sign-in returned no authorization code.")
    }
    return MCPOAuthResult(code: code, state: state, iss: value("iss"))
}

func validateTask(
    name: String, prompt: String, cron: String, runAt: String, timezone: String = TimeZone.current.identifier
) -> String? {
    if name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty {
        return "Task name and prompt are required."
    }
    if cron.isEmpty == runAt.isEmpty {
        return "Choose either a recurring cron or a one-time run time."
    }
    if TimeZone(identifier: timezone) == nil {
        return "Choose a valid time zone."
    }
    if !runAt.isEmpty, taskRunDate(runAt) == nil {
        return "Choose a valid date and time."
    }
    return nil
}

/// Server timestamps are absolute instants; the date picker displays them in its time zone.
func taskRunDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
}

func friendlyError(_ error: Error) -> String {
    if let apiError = error as? APIError {
        if apiError.statusCode == 401 { return "Authentication failed. Check the server token in Settings." }
        struct Body: Decodable {
            struct Detail: Decodable { var message: String? }
            var error: String?
            var details: [Detail]?
        }
        if let body = try? JSONDecoder().decode(Body.self, from: Data(apiError.body.utf8)), let message = body.error,
            !message.isEmpty {
            if let detail = body.details?.first?.message { return message + ": " + detail }
            return message
        }
    }
    return error.localizedDescription
}

func timeLabel(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return "Today " + time }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + time
    }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func activityTime(_ value: String?) -> String {
    guard let value else { return "" }
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    guard let date = (try? fractional.parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value)) else {
        return value
    }
    return timeLabel(date)
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    var trimmingTrailingSlashes: String {
        var value = self
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
