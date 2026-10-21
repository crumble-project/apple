import Foundation
import Synchronization
import Testing

@testable import apfelkern

private let agentJSON = #"""
  {"id":"bot","name":"Desk","avatar":"bot","description":"","instructions":"","provider":"openai",
   "model":"gpt-4.1","enabled":true,"tools":["desktop"],"skills":[],"mcpServers":[],"delegates":[],
   "desktopModel":{"provider":"opencode-go","model":"gpt-6-luna"},"createdAt":"now","updatedAt":"now"}
  """#

@Test func capabilitiesReportBotDesktops() async throws {
  try await withClient(handler: { _ in
    StubResponse(body: Data(#"{"coding":true,"desktop":true}"#.utf8))
  }) { client in
    let capabilities = try await client.capabilities()
    #expect(capabilities.desktop)
  }
}

@Test func agentsCarryTheirDesktopModel() async throws {
  try await withClient(handler: { _ in StubResponse(body: Data(agentJSON.utf8)) }) { client in
    let agent = try await client.updateAgent("bot", patch: ["name": .string("Desk")])
    #expect(agent.desktopModel == DesktopModel(provider: "opencode-go", model: "gpt-6-luna"))
  }
}

@Test func aNullDesktopModelIsSentToClearTheOverride() async throws {
  try await withClient(handler: { request in
    let body = try requestJSON(request)
    #expect(body["desktopModel"] == .null)
    #expect(request.httpMethod == "PATCH")
    return StubResponse(body: Data(agentJSON.utf8))
  }) { client in
    _ = try await client.updateAgent("bot", patch: ["desktopModel": .null])
  }
}

private let jobsJSON = #"""
  {"jobs":[{"name":"github","conversationId":"bot:15","status":"working","usage":{"models":{
    "opencode-go/gpt-6-luna":{"input":800,"output":400,"cacheRead":7000,"cacheWrite":0,"totalTokens":8200,
      "cost":{"input":0.0001,"output":0.0002,"cacheRead":0.0007,"cacheWrite":0,"total":0.001}},
    "faux/other":{"input":200,"output":100,"cacheRead":0,"cacheWrite":0,"totalTokens":300,
      "cost":{"input":0.0005,"output":0.0005,"cacheRead":0,"cacheWrite":0,"total":0.001}}},"tools":{}}},
    {"name":"fresh","conversationId":"bot:20","status":"idle"}]}
  """#

@Test func desktopJobsListTheirUsageSummedOverModels() async throws {
  try await withClient(handler: { request in
    #expect(request.url?.path == "/prefix/v1/agents/bot/desktop-jobs")
    return StubResponse(body: Data(jobsJSON.utf8))
  }) { client in
    let jobs = try await client.desktopJobs("bot")
    #expect(jobs.map(\.name) == ["github", "fresh"])
    #expect(jobs[0].isWorking)
    #expect(jobs[0].usage == JobUsage(inputTokens: 1000, outputTokens: 500, cachedTokens: 7000, cost: 0.002))
    #expect(jobs[1].usage == nil)
  }
}

@Test func aDesktopToolResultNamesItsJob() throws {
  let message = try JSONDecoder().decode(Message.self, from: Data(#"""
    {"id":"m1","role":"toolResult","toolName":"desktop","content":"Started github.",
     "toolDetails":{"name":"github","status":"working","conversationId":"bot:15"}}
    """#.utf8))
  #expect(DesktopJob(message: message)?.name == "github")
  #expect(CodingJob(message: message) == nil)
}

@Test func aDesktopJobReportIsLabelledWithItsJob() throws {
  let message = try JSONDecoder().decode(Message.self, from: Data(#"""
    {"id":"m2","role":"user","content":"Please log in.","origin":{"kind":"desktop","name":"github"}}
    """#.utf8))
  #expect(messageLabel(message) == "Desktop job · github")
}

private let controlJSON = #"{"holder":"owner","changes":3,"updatedAt":"2026-10-21T19:00:00.000Z"}"#

@Test func theOwnerTakesControlAndReadsItBack() async throws {
  try await withClient(handler: { request in
    #expect(request.url?.path == "/prefix/v1/agents/bot/desktop/control")
    if request.httpMethod == "PUT" {
      let body = try requestJSON(request)
      #expect(body == .object(["holder": .string("owner")]))
    }
    return StubResponse(body: Data(controlJSON.utf8))
  }) { client in
    let taken = try await client.setDesktopControl("bot", holder: .owner)
    #expect(taken == DesktopControl(holder: .owner, changes: 3, updatedAt: "2026-10-21T19:00:00.000Z"))
    #expect(try await client.desktopControl("bot").holder == .owner)
  }
}

@Test func desktopEventsDeliverControlChangesAndSkipHeartbeats() async throws {
  let stream = "event: heartbeat\ndata: {}\n\nevent: control\ndata: \(controlJSON)\n\n"
  try await withClient(handler: { request in
    #expect(request.url?.path == "/prefix/v1/agents/bot/desktop/events")
    return StubResponse(contentType: "text/event-stream", body: Data(stream.utf8), open: true)
  }) { client in
    let received = Mutex<[DesktopControl]>([])
    let task = Task {
      try await client.desktopEvents("bot") { state in received.withLock { $0.append(state) } }
    }
    for _ in 0..<100 where received.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
    task.cancel()
    #expect(received.withLock { $0 } == [DesktopControl(holder: .owner, changes: 3, updatedAt: "2026-10-21T19:00:00.000Z")])
  }
}

@Test func aViewerLinkResolvesUnderTheServersPrefix() async throws {
  try await withClient(handler: { request in
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/prefix/v1/agents/bot/desktop/viewer")
    return StubResponse(status: 201, body: Data(#"{"path":"/desktop-viewer/abc_-1","expiresAt":"soon"}"#.utf8))
  }) { client in
    let link = try await client.desktopViewer("bot")
    #expect(link.url.path == "/prefix/desktop-viewer/abc_-1")
    #expect(link.url.scheme == "https")
    #expect(link.expiresAt == "soon")
  }
}
