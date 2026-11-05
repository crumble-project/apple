import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  private func loginSession(_ status: String) -> String {
    #"{"id":"l1","provider":"openai","method":"oauth","status":"\#(status)","createdAt":1,"#
      + #""expiresAt":2,"prompt":null,"events":[],"failure":null}"#
  }

  @MainActor @Test func providerSignInResumesFromProvidersAndConfirmsOnlyAfterTheServerDoes() async throws {
    nonisolated(unsafe) var polls = 0
    let pending = loginSession("pending")
    let succeeded = loginSession("succeeded")
    let listed =
      #"[{"provider":"openai","name":"OpenAI","configured":false,"authMethods":[],"#
      + #""credentialType":null,"apiKey":{"configured":false,"passwordManager":null,"reference":null},"#
      + #""activeLoginId":"l1","externalAuth":null}]"#
    let model = AppModel(
      client: StubProtocol.client(token: "token") { request in
        if request.url?.path == "/v1/providers" { return (200, listed) }
        polls += 1
        return (200, polls < 2 ? pending : succeeded)
      })
    model.loadProviders()
    for _ in 0..<200 where model.providerLogins.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.providerLogins["openai"]?.id == "l1")
    #expect(model.notice.isEmpty)
    for _ in 0..<400 where model.notice.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.notice == "Signed in to OpenAI")
    #expect(model.providerLogins.isEmpty)
  }

  @MainActor @Test func changingConnectionForgetsProviderSignIns() async throws {
    let pending = loginSession("pending")
    let model = AppModel(client: StubProtocol.client(token: "token") { _ in (202, pending) })
    model.startProviderLogin("openai", method: .oauth)
    for _ in 0..<200 where model.providerLogins.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.providerLogins["openai"] != nil)
    model.applyConnection(StubProtocol.client(token: "other") { _ in (404, "") })
    #expect(model.providerLogins.isEmpty)
    #expect(model.providerLoginRequests.isEmpty)
  }
}
