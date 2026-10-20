import Foundation
import OpenAPIRuntime

extension APIClient {
  public func chatEvents(_ agentID: String, onEvent: @Sendable (String) async -> Void) async throws -> Never {
    let body = try await invoke(timeout: 24 * 60 * 60) {
      try await $0.streamChatEvents(.init(path: .init(id: agentID))).ok.body.textEventStream
    }
    try await events(body, parser: SSEParser(), onEvent: onEvent)
  }

  public func activityEvents(onEvent: @Sendable (String) async -> Void) async throws -> Never {
    let body = try await invoke(timeout: 24 * 60 * 60) {
      try await $0.streamActivityEvents(.init()).ok.body.textEventStream
    }
    try await events(body, parser: SSEParser(accepting: ["activity"]), onEvent: onEvent)
  }

  private func events(_ body: HTTPBody, parser: SSEParser, onEvent: @Sendable (String) async -> Void)
    async throws -> Never {
    var parser = parser
    var line = Data()
    var previousWasCR = false
    for try await chunk in body {
      try Task.checkCancellation()
      for byte in chunk {
        if byte == 10 && previousWasCR {
          previousWasCR = false
          continue
        }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 {
          if let payload = try parser.feed(decodeUTF8(line)) { await onEvent(payload) }
          line.removeAll(keepingCapacity: true)
        } else {
          line.append(byte)
        }
      }
    }
    try Task.checkCancellation()
    if !line.isEmpty, let payload = try parser.feed(decodeUTF8(line)) { await onEvent(payload) }
    if let payload = try parser.feed("") { await onEvent(payload) }
    throw SSEClosedError()
  }
}

/// Splits SSE frames and validates accepted payloads with generated event-schema models.
public struct SSEParser {
  private var data: [String] = []
  private var eventType = "message"
  private let accepting: Set<String>

  public init(accepting: Set<String> = ["snapshot", "message"]) {
    self.accepting = accepting
  }

  public struct InvalidPayload: Error, LocalizedError {
    public var reason: String
    public var errorDescription: String? { reason }
  }

  public mutating func feed(_ line: String) throws -> String? {
    if line.hasPrefix("event:") {
      eventType = fieldValue(line.dropFirst(6))
    } else if line.hasPrefix("data:") {
      data.append(fieldValue(line.dropFirst(5)))
    } else if line.isEmpty {
      return try dispatch()
    }
    return nil
  }

  private func fieldValue(_ value: Substring) -> String {
    String(value.first == " " ? value.dropFirst() : value)
  }

  private mutating func dispatch() throws -> String? {
    defer { eventType = "message"; data.removeAll(keepingCapacity: true) }
    guard !data.isEmpty else { return nil }
    let payload = data.joined(separator: "\n")
    let bytes = Data(payload.utf8)
    if eventType == "heartbeat" {
      _ = try? JSONDecoder().decode(Components.Schemas.EventHeartbeat.self, from: bytes)
      return nil
    }
    guard accepting.contains(eventType) else { return nil }
    do {
      if eventType == "activity" {
        let type = try JSONDecoder().decode(JSONValue.self, from: bytes)["type"]?.stringValue
        guard type == "reply" || type == "chat-preview" else { return nil }
        _ = try JSONDecoder().decode(Components.Schemas.EventActivity.self, from: bytes)
      } else {
        let snapshot = try JSONDecoder().decode(Components.Schemas.EventChatSnapshot.self, from: bytes)
        guard !snapshot.agentId.isEmpty else {
          throw InvalidPayload(reason: "snapshot event missing agentId")
        }
      }
    } catch let error as InvalidPayload {
      throw error
    } catch {
      throw InvalidPayload(reason: "invalid SSE payload: \(error)")
    }
    return payload
  }
}
