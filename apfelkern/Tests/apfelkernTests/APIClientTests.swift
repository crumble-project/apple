import Foundation
import Synchronization
import Testing
@testable import apfelkern

@Test func generatedSuccessUsesInjectedSessionAndAuthentication() async throws {
  try await withClient(handler: { request in
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/prefix/v1/capabilities")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.timeoutInterval == 20)
    return StubResponse(body: Data(#"{"coding":true,"desktop":false,"jobKinds":["coding"],"future":1}"#.utf8))
  }) { client in
    let capabilities = try await client.capabilities()
    #expect(capabilities.coding)
  }
}

@Test func generatedAuthenticationFailurePreservesAPIError() async throws {
  try await withClient(token: "", handler: { request in
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    return StubResponse(status: 401, contentType: "text/plain", body: Data(" Unauthorized \n".utf8))
  }) { client in
    do {
      _ = try await client.agents()
      Issue.record("Expected authentication failure")
    } catch let error as APIError {
      #expect(error.statusCode == 401)
      #expect(error.method == "GET")
      #expect(error.path == "/v1/agents")
      #expect(error.body == "Unauthorized")
    }
  }
}

@Test func generatedAPIErrorsKeepBoundedBodiesAndStatus() async throws {
  try await withClient(handler: { _ in
    StubResponse(status: 503, contentType: "text/html", body: Data(repeating: 65, count: 20_000))
  }) { client in
    do {
      _ = try await client.capabilities()
      Issue.record("Expected API error")
    } catch let error as APIError {
      #expect(error.statusCode == 503)
      #expect(error.body.utf8.count == 8 << 10)
    }
  }
}

@Test func generatedAttachmentOperationEscapesPathAndReturnsBytes() async throws {
  let bytes = Data([0, 255, 13, 10, 128])
  try await withClient(handler: { request in
    #expect(request.url?.absoluteString.hasSuffix("/v1/agents/bot/attachments/entry%2Fwith%20space/2") == true)
    return StubResponse(contentType: "image/png", body: bytes)
  }) { client in
    let attachment = try await client.attachment("bot", entryID: "entry/with space", index: 2)
    #expect(attachment == bytes)
  }
}

@Test func generatedMessagesCarryFileIDsWithAttachmentTimeout() async throws {
  let requests = Mutex(0)
  let execution = #"""
    {"id":"run","agentId":"bot","conversationId":"chat","scheduleId":null,"submissionId":null,
     "requestId":"request","prompt":"hello","status":"pending","error":null,"createdAt":"now","updatedAt":"now"}
    """#
  try await withClient(handler: { request in
    requests.withLock { $0 += 1 }
    #expect(request.timeoutInterval == 120)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/prefix/v1/agents/bot/messages")
    let body = try requestJSON(request)
    #expect(body["timezone"] == .string("Europe/Berlin"))
    #expect(body["replyTo"] == nil)
    #expect(body["attachments"] == nil)
    #expect(body["files"] == .array([.string("f1"), .string("f2")]))
    return StubResponse(status: 202, body: Data(execution.utf8))
  }) { client in
    try await client.sendChatMessage("bot", content: "hello", requestID: "request", replyTo: "",
      files: ["f1", "f2"], timezone: "Europe/Berlin")
  }
  #expect(requests.withLock { $0 } == 1)
}

private let uploadedFile = #"""
  {"file":{"id":"0b7c6a9e-7d3f-4c55-9d1a-1f1e5b2f3a40","name":"Trip plan ü.png","mimeType":"image/png",
   "size":5,"createdAt":"now"},"existed":false}
  """#

@Test func uploadsSendRawBytesWithTheFileNameAndType() async throws {
  let bytes = Data([0, 255, 13, 10, 128])
  let file = PendingAttachment(name: "Trip plan ü+&.png", mimeType: "image/png", data: bytes)
  let paths = Mutex<[String]>([])
  try await withClient(handler: { request in
    paths.withLock { $0.append(request.url?.path ?? "") }
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 120)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
    #expect(request.value(forHTTPHeaderField: "X-File-Name") == "Trip%20plan%20%C3%BC%2B%26.png")
    #expect(requestBody(request) == bytes)
    return StubResponse(status: 201, body: Data(uploadedFile.utf8))
  }) { client in
    let botFile = try await client.uploadFile("bot", file)
    let groupFile = try await client.uploadGroupFile("trip", file)
    #expect([botFile, groupFile] == Array(repeating: "0b7c6a9e-7d3f-4c55-9d1a-1f1e5b2f3a40", count: 2))
  }
  #expect(paths.withLock { $0 } == ["/prefix/v1/agents/bot/files", "/prefix/v1/group-chats/trip/files"])
}

@Test func filesDownloadByID() async throws {
  let bytes = Data([137, 80, 78, 71])
  let paths = Mutex<[String]>([])
  try await withClient(handler: { request in
    paths.withLock { $0.append(request.url?.path ?? "") }
    #expect(request.httpMethod == "GET")
    return StubResponse(contentType: "application/octet-stream", body: bytes)
  }) { client in
    let botFile = try await client.file("bot", fileID: "f1")
    let groupFile = try await client.groupFile("trip", fileID: "f2")
    #expect([botFile, groupFile] == [bytes, bytes])
  }
  #expect(paths.withLock { $0 } == ["/prefix/v1/agents/bot/files/f1", "/prefix/v1/group-chats/trip/files/f2"])
}

@Test func nullableGeneratedResourceFailsWithoutFabricatingAnAgent() async throws {
  try await withClient(handler: { _ in StubResponse(body: Data("null".utf8)) }) { client in
    await #expect(throws: DecodingError.self) { try await client.updateAgent("bot", patch: [:]) }
  }
}

@Test func generatedSchedulePatchPreservesExplicitNullAndDate() async throws {
  let schedule = #"""
    {"id":"task","agentId":"bot","name":"Task","prompt":"hello","kind":"prompt","command":null,
     "timeoutSeconds":60,"notify":true,"eventSourceId":null,"cron":null,"timezone":"UTC",
     "runAt":"2026-07-01T09:00:00.123Z","enabled":true,"nextRunAt":null,"nextRunLabel":"","description":"",
     "timing":"","createdAt":"now","createdByAgentId":null}
    """#
  try await withClient(handler: { request in
    let body = try requestJSON(request)
    #expect(body["cron"] == .null)
    #expect(body["runAt"] == .string("2026-07-01T09:00:00.123Z"))
    return StubResponse(body: Data(schedule.utf8))
  }) { client in
    let task = try await client.updateSchedule("task", patch: [
      "cron": .null, "runAt": .string("2026-07-01T09:00:00.123Z")])
    #expect(task.runAt == "2026-07-01T09:00:00.123Z")
  }
}

@Test func generatedScheduleRunRetainsExecutionNavigationAndDetails() async throws {
  let response = #"""
    {"admitted":true,"result":{"id":"run","agentId":"bot","conversationId":"chat","status":"pending",
     "prompt":"hello","error":null,"createdAt":"2026-07-01","updatedAt":"2026-07-02"}}
    """#
  try await withClient(handler: { _ in StubResponse(status: 202, body: Data(response.utf8)) }) { client in
    let execution = try await client.runSchedule("task")
    #expect(execution.id == "run")
    #expect(execution.agentId == "bot")
    #expect(execution.conversationId == "chat")
    #expect(execution.status == "pending")
    #expect(execution.prompt == "hello")
    #expect(execution.error == nil)
    #expect(execution.createdAt == "2026-07-01")
    #expect(execution.updatedAt == "2026-07-02")
  }
}

@Test(arguments: [
  #"{"admitted":false,"result":{"id":"rejected","status":"pending"}}"#,
  #"{"admitted":true}"#,
  #"{"admitted":true,"result":{"status":"pending"}}"#
]) func generatedScheduleRunRejectsUnadmittedOrMissingResult(_ response: String) async throws {
  try await withClient(handler: { _ in StubResponse(status: 202, body: Data(response.utf8)) }) { client in
    await #expect(throws: DecodingError.self) { try await client.runSchedule("task") }
  }
}

@Test func generatedSSESkipsUnknownFramesAndHeartbeats() async throws {
  let preview = #"{"type":"chat-preview","agentId":"bot","agentName":"Bot","lastMessage":"hello"}"#
  let stream = "event: heartbeat\r\ndata: {}\r\n\r\nevent: future\ndata: invalid\n\nevent: activity\rdata: " + preview + "\r\r"
  let received = Mutex<[String]>([])
  try await withClient(handler: { request in
    #expect(request.timeoutInterval == serverSentEventsIdleTimeout)
    return StubResponse(contentType: "text/event-stream", body: Data(stream.utf8))
  }) { client in
    do {
      try await client.activityEvents { payload in received.withLock { $0.append(payload) } }
    } catch is SSEClosedError {
      #expect(received.withLock { $0 } == [preview])
    }
  }
}

@Test func generatedOperationCancelsTheInjectedSessionTask() async throws {
  let (requests, continuation) = AsyncStream<Void>.makeStream()
  try await withClient(handler: { _ in
    continuation.yield(())
    return StubResponse(body: Data(), hold: true)
  }) { client in
    let task = Task { try await client.capabilities() }
    var iterator = requests.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
  continuation.finish()
}

@Test func generatedActivityFacadeRejectsSparseReplies() throws {
  let sparse = #"{"type":"reply","agentId":"bot","agentName":"Bot"}"#
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(ActivityEvent.self, from: Data(sparse.utf8))
  }
  let preview = #"{"type":"chat-preview","agentId":"bot","agentName":"Bot","lastMessage":"hello","future":true}"#
  let event = try JSONDecoder().decode(ActivityEvent.self, from: Data(preview.utf8))
  #expect(event.lastMessage == "hello")
  #expect(try JSONDecoder().decode(ActivityEvent.self, from: JSONEncoder().encode(event)) == event)
}

private let groupSnapshot = #"""
  {"groupChat":{"id":"trip","name":"Trip","memberIds":["ada","grace"],"createdAt":"now","updatedAt":"now"},
   "activity":{"paused":true,"botTurns":8,"members":[
     {"agentId":"ada","status":"running","error":null},{"agentId":"grace","status":"disabled","error":null}]},
   "messages":[
     {"id":"trip:1:0","entryId":"trip:1","role":"user","content":"Pack light","origin":{"kind":"owner"},
      "replyReferences":[]},
     {"id":"trip:2:0","entryId":"trip:2","role":"toolResult","content":"Reacted 👍","toolName":"react",
      "toolDetails":{"emoji":"👍"},"replyTo":"trip:1","origin":{"kind":"bot","agentId":"ada","name":"Ada"},
      "replyReferences":[]}],
   "hasMore":false,"oldestEntryId":"trip:1","updatedAt":1}
  """#

@Test func groupMessagesCarryReplyAndFileIDs() async throws {
  let requests = Mutex(0)
  try await withClient(handler: { request in
    requests.withLock { $0 += 1 }
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/prefix/v1/group-chats/trip/messages")
    #expect(request.timeoutInterval == 120)
    let body = try requestJSON(request)
    #expect(body["content"] == .string("Route attached"))
    #expect(body["replyTo"] == .string("trip:3"))
    #expect(body["attachments"] == nil)
    #expect(body["files"] == .array([.string("f1")]))
    return StubResponse(status: 201, body: Data(#"{"requestId":"request","entryId":"trip:4"}"#.utf8))
  }) { client in
    try await client.sendGroupMessage(
      "trip", content: "Route attached", requestID: "request", replyTo: "trip:3", files: ["f1"])
  }
  #expect(requests.withLock { $0 } == 1)
}

@Test func groupSnapshotsDecodeActivityAndReactions() async throws {
  try await withClient(handler: { request in
    #expect(request.url?.path == "/prefix/v1/group-chats/trip/chat")
    return StubResponse(body: Data(groupSnapshot.utf8))
  }) { client in
    let snapshot = try await client.groupChat("trip")
    #expect(snapshot.groupChat.memberIds == ["ada", "grace"])
    #expect(snapshot.activity.paused)
    #expect(snapshot.activity.member("ada")?.status == .running)
    #expect(snapshot.activity.member("grace")?.status == .disabled)
    #expect(snapshot.messages.last?.toolName == "react")
    #expect(Reaction.byReplyTarget(snapshot.messages) == ["trip:1:0": [Reaction.Mark(emoji: "👍", from: "Ada")]])
  }
}

@Test func groupEventsDecodeGroupSnapshotsAndSkipHeartbeats() async throws {
  let compact = try JSONEncoder().encode(JSONDecoder().decode(JSONValue.self, from: Data(groupSnapshot.utf8)))
  let payload = try #require(String(bytes: compact, encoding: .utf8))
  let stream = "event: heartbeat\ndata: {}\n\nevent: snapshot\ndata: " + payload + "\n\n"
  let received = Mutex<[String]>([])
  try await withClient(handler: { request in
    #expect(request.url?.path == "/prefix/v1/group-chats/trip/events")
    return StubResponse(contentType: "text/event-stream", body: Data(stream.utf8))
  }) { client in
    do {
      try await client.groupChatEvents("trip") { payload in received.withLock { $0.append(payload) } }
    } catch is SSEClosedError {
      let events = received.withLock { $0 }
      #expect(events.count == 1)
      let snapshot = try JSONDecoder().decode(GroupChatSnapshot.self, from: Data(events[0].utf8))
      #expect(snapshot.groupChat.name == "Trip")
    }
  }
  var parser = SSEParser(snapshots: .group)
  _ = try parser.feed("event: snapshot")
  _ = try parser.feed(#"data: {"agentId":"bot","messages":[]}"#)
  #expect(throws: SSEParser.InvalidPayload.self) { try parser.feed("") }
}

@Test func groupReplyEventsKeepTheirGroup() throws {
  let reply = #"""
    {"type":"reply","eventId":"e","serverId":"s","agentId":"ada","agentName":"Ada","entryId":"trip:5",
     "origin":"group","preview":"Booked.","createdAt":"now","groupId":"trip","groupName":"Trip"}
    """#
  let event = try JSONDecoder().decode(ActivityEvent.self, from: Data(reply.utf8))
  #expect(event.groupId == "trip")
  #expect(event.groupName == "Trip")
  #expect(try JSONDecoder().decode(ActivityEvent.self, from: JSONEncoder().encode(event)) == event)
}

@Test func memoriesReportTheirSource() async throws {
  let memories = #"""
    [{"id":"a","agentId":"ada","content":"older","source":null,"createdAt":"now","updatedAt":"now"},
     {"id":"b","agentId":"ada","content":"Leaves Friday","createdAt":"now","updatedAt":"now",
      "source":{"kind":"group","groupId":"trip","name":"Trip"}}]
    """#
  try await withClient(handler: { _ in StubResponse(body: Data(memories.utf8)) }) { client in
    let result = try await client.memories("ada")
    #expect(result.map(\.source) == [nil, MemorySource(kind: "group", name: "Trip", groupId: "trip")])
  }
}

@Test func groupEventsArriveWhileTheStreamStaysOpen() async throws {
  let compact = try JSONEncoder().encode(JSONDecoder().decode(JSONValue.self, from: Data(groupSnapshot.utf8)))
  let payload = try #require(String(bytes: compact, encoding: .utf8))
  let (events, continuation) = AsyncStream<String>.makeStream()
  try await withClient(handler: { _ in
    StubResponse(contentType: "text/event-stream", body: Data(("event: snapshot\ndata: " + payload + "\n\n").utf8),
                 open: true)
  }) { client in
    let stream = Task { try await client.groupChatEvents("trip") { continuation.yield($0) } }
    defer { stream.cancel() }
    let first = Task {
      var iterator = events.makeAsyncIterator()
      return await iterator.next()
    }
    let timeout = Task {
      try await Task.sleep(for: .seconds(2))
      first.cancel()
    }
    #expect(await first.value == payload)
    timeout.cancel()
  }
}
