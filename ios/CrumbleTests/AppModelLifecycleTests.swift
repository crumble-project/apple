import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  @MainActor @Test func suspensionPreservesComposerRouteAndReconcilesOnResume() async {
    let client = StubProtocol.client { request in
      switch request.url?.path {
      case "/v1/agents/a1/chat":
        (
          200,
          #"{"agentId":"a1","status":"idle","messages":[{"id":"a1:1:0","role":"assistant","content":"ready"}]}"#
        )
      case "/v1/events", "/v1/agents/a1/events": (401, "")
      default: (404, "")
      }
    }
    let model = AppModel(client: client)
    model.selectAgent("a1")
    for _ in 0..<100 where model.snapshot == nil { try? await Task.sleep(for: .milliseconds(5)) }
    model.draft = "keep this draft"
    model.attachments = [
      PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("draft".utf8))
    ]
    let route = model.route

    model.suspendStreams()
    #expect(model.route == route)
    #expect(model.draft == "keep this draft")
    #expect(model.attachments.map(\.name) == ["notes.txt"])

    model.resumeStreams()
    for _ in 0..<100 where model.loading { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(model.route == route)
    #expect(model.draft == "keep this draft")
    #expect(model.attachments.map(\.name) == ["notes.txt"])
    #expect(model.messages.contains { $0.text == "ready" })
    model.suspendStreams()
  }

  @MainActor @Test func resumePreservesWorkspaceFormWhenNoChatIsSelected() async {
    let model = AppModel(client: StubProtocol.client { _ in (401, "") })
    model.route = .memory
    model.memoryDraft = MemoryDraft(memoryID: "", content: "Unsaved note", agentID: nil)
    let draftID = model.memoryDraft?.id
    model.suspendStreams()
    model.resumeStreams()
    for _ in 0..<20 { await Task.yield() }
    #expect(model.route == .memory)
    #expect(model.memoryDraft?.id == draftID)
    #expect(model.memoryDraft?.content == "Unsaved note")
    model.suspendStreams()
  }
}
