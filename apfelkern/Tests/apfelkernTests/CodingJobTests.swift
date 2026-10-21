import Foundation
import Testing

@testable import apfelkern

private func decode(_ json: String) throws -> Message {
  try JSONDecoder().decode(Message.self, from: Data(json.utf8))
}

@Test func codingToolResultDecodesJob() throws {
  let message = try decode(
    #"{"id":"m1","role":"toolResult","toolName":"coding","#
      + #""toolDetails":{"name":"fix-login","status":"working","conversationId":"c1"}}"#)
  #expect(CodingJob(message: message) == CodingJob(name: "fix-login", conversationId: "c1", status: "working"))
  #expect(CodingJob(message: message)?.isWorking == true)
}

@Test func codingStatusListingIsNotAJob() throws {
  let message = try decode(#"{"id":"m1","role":"toolResult","toolName":"coding","content":"none"}"#)
  #expect(CodingJob(message: message) == nil)
}

@Test func codingOriginHasLabel() throws {
  let message = try decode(
    #"{"id":"m1","role":"user","content":"Done","origin":{"kind":"coding","name":"fix-login"}}"#)
  #expect(messageLabel(message) == "Coding job · fix-login")
}

@Test func jobHistoryFoldsToolResultsIntoCalls() throws {
  let calls = #"{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"swift test"}},"#
    + #"{"type":"toolCall","id":"t2","name":"read","arguments":{"path":"a.swift"}}"#
  let messages = try [
    decode(#"{"id":"u","role":"user","content":"Fix the build"}"#),
    decode(#"{"id":"a","role":"assistant","blocks":[{"type":"text","text":"Running tests."},"# + calls + "]}"),
    decode(#"{"id":"r","role":"toolResult","toolCallId":"t1","toolName":"bash","content":"boom","isError":true}"#)
  ]
  let items = CodingJobItem.items(from: messages)
  #expect(items.count == 4)
  guard case .tool(let bash) = items[2], case .tool(let read) = items[3] else {
    Issue.record("expected tool items")
    return
  }
  #expect(bash.subject == "swift test" && bash.output == "boom" && bash.isError && bash.finished)
  #expect(read.subject == "a.swift" && !read.finished)
}

@Test func tailKeepsLastLines() {
  let result = tailLines("1\n2\n3\n4\n", maxLines: 2)
  #expect(result.text == "3\n4" && result.omitted == 2)
  #expect(tailLines("1", maxLines: 2) == ("1", 0))
}

@Test func draftDefaultsCodingOff() {
  #expect(AgentDraft(isNew: true, agentID: "").toolsCoding == false)
}
