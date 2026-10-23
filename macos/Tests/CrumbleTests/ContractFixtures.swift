import apfelkern
import Foundation

private let fixtureDate = "2026-10-19T12:00:00Z"

private func fixtureJSON(_ source: String, defaults: [String: JSONValue]) -> String {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) else {
        preconditionFailure("Expected valid fixture JSON")
    }
    func complete(_ value: JSONValue) -> JSONValue {
        guard case .object(let fields) = value else { preconditionFailure("Expected fixture object") }
        return .object(defaults.merging(fields) { _, supplied in supplied })
    }
    if case .array(let values) = value { return JSONValue.array(values.map(complete)).prettyPrinted }
    return complete(value).prettyPrinted
}

func agentFixture(_ source: String) -> String {
    fixtureJSON(source, defaults: [
        "id": .string("a1"), "name": .string("Atlas"), "avatar": .string("bot:atlas"),
        "description": .string(""), "instructions": .string(""), "provider": .string("example"),
        "model": .string("example"), "enabled": .bool(true), "tools": .array([]),
        "skills": .array([]), "mcpServers": .array([]), "delegates": .array([]),
        "createdAt": .string(fixtureDate), "updatedAt": .string(fixtureDate)
    ])
}

func memoryFixture(_ source: String) -> String {
    fixtureJSON(source, defaults: [
        "agentId": .null, "createdAt": .string(fixtureDate), "updatedAt": .string(fixtureDate)
    ])
}

func chatFixture(_ agentID: String = "a1", status: String = "idle") -> String {
    JSONValue.object([
        "agentId": .string(agentID), "status": .string(status), "messages": .array([]),
        "hasMore": .bool(false), "oldestEntryId": .null, "conversationId": .string("c1"),
        "conversation": .object([
            "id": .string("c1"), "agentId": .string(agentID), "title": .string("Chat"),
            "createdAt": .string(fixtureDate), "updatedAt": .string(fixtureDate)
        ]),
        "partial": .string(""), "updatedAt": .number(0), "error": .null
    ]).prettyPrinted.replacingOccurrences(of: "\n", with: "")
}

func executionFixture() -> String {
    JSONValue.object([
        "id": .string("e1"), "agentId": .string("a1"), "conversationId": .string("c1"),
        "scheduleId": .null, "submissionId": .null,
        "requestId": .string("00000000-0000-4000-8000-000000000001"),
        "prompt": .string("hello"), "status": .string("pending"), "error": .null,
        "createdAt": .string(fixtureDate), "updatedAt": .string(fixtureDate)
    ]).prettyPrinted
}

func scheduleFixture(_ source: String) -> String {
    fixtureJSON(source, defaults: [
        "cron": .null, "runAt": .null, "nextRunAt": .null, "createdByAgentId": .null,
        "createdAt": .string(fixtureDate)
    ])
}
