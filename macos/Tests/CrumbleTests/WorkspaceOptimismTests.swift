import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor @Test func memoryCreateAppearsBeforeServerResponseAndReconciles() async throws {
        let client = StubProtocol.client { request in
            if request.httpMethod == "POST", request.url?.path == "/v1/memories" {
                return (201, memoryFixture(#"{"id":"m1","content":"Remember this"}"#))
            }
            return (404, "")
        }
        let model = AppModel(client: client)
        model.workspaceRoute = .memory
        model.openMemoryForm("")
        model.memoryDraft?.content = "Remember this"

        model.saveMemory()

        #expect(model.memoryDraft == nil)
        #expect(model.workspaceRoute == .memory)
        #expect(model.sharedMemories.count == 1)
        #expect(model.sharedMemories[0].id.hasPrefix("pending-memory-"))
        while model.loading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.sharedMemories.map(\.id) == ["m1"])
        #expect(model.workspaceRoute == .memory)
        #expect(model.errorText.isEmpty)
    }

    @MainActor @Test func failedMemoryDeleteRestoresOnlyDeletedRecord() async throws {
        let client = StubProtocol.client { request in
            request.httpMethod == "DELETE" ? (500, #"{"error":"busy"}"#) : (404, "")
        }
        let model = AppModel(client: client)
        model.workspaceRoute = .memory
        model.sharedMemories = [Memory(id: "m1", content: "First"), Memory(id: "m2", content: "Second")]

        model.deleteMemory("m1")
        #expect(model.sharedMemories.map(\.id) == ["m2"])
        while model.loading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.sharedMemories.map(\.id) == ["m1", "m2"])
        #expect(model.sharedMemories.map(\.content) == ["First", "Second"])
        #expect(model.errorText.contains("busy"))
    }

    @MainActor @Test func failedMemorySaveDoesNotReplaceNewerDraft() async throws {
        let client = StubProtocol.client { request in
            request.httpMethod == "POST" ? (500, #"{"error":"busy"}"#) : (404, "")
        }
        let model = AppModel(client: client)
        model.workspaceRoute = .memory
        model.openMemoryForm("")
        model.memoryDraft?.content = "Old draft"
        model.saveMemory()

        model.openMemoryForm("")
        model.memoryDraft?.content = "Newer draft"
        while model.loading { try await Task.sleep(for: .milliseconds(5)) }

        #expect(model.memoryDraft?.content == "Newer draft")
        #expect(model.sharedMemories.isEmpty)
        #expect(model.errorText.contains("busy"))
    }

    @MainActor @Test func aLateBotListKeepsASavedAvatar() async throws {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        let bot = Agent(id: "a1", name: "Atlas")
        model.agents = [bot]
        await controller.hold("/v1/agents")
        await controller.hold("/v1/agents/a1")
        model.refresh()
        #expect(await controller.waitForHeld("/v1/agents"))

        model.avatarBoard.select(bot)
        var edited = bot.avatar
        edited.color = "#112233"
        model.avatarBoard.value = edited
        model.saveAvatar()
        #expect(model.agents[0].avatar.color == "#112233")
        #expect(await controller.waitForHeld("/v1/agents/a1"))
        await controller.release("/v1/agents/a1", body: try agentJSON(avatar: edited))
        while !model.avatarBoard.saved { try await Task.sleep(for: .milliseconds(5)) }

        await controller.release("/v1/agents", body: "[" + (try agentJSON(avatar: bot.avatar)) + "]")
        while model.loading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.agents.first?.avatar.color == "#112233")
    }

    @MainActor @Test func aFailedAvatarSaveRollsBackWithoutABanner() async throws {
        let client = StubProtocol.client { request in
            request.httpMethod == "PATCH" ? (500, #"{"error":"busy"}"#) : (404, "")
        }
        let model = AppModel(client: client)
        let bot = Agent(id: "a1", name: "Atlas")
        model.agents = [bot]
        model.avatarBoard.select(bot)
        var edited = bot.avatar
        edited.color = "#112233"
        model.avatarBoard.value = edited

        model.saveAvatar()
        #expect(model.agents[0].avatar.color == "#112233")
        while model.avatarBoard.isSaving { try await Task.sleep(for: .milliseconds(5)) }

        #expect(model.agents[0].avatar.color == bot.avatar.color)
        #expect(model.avatarBoard.value.color == "#112233")
        #expect(model.avatarBoard.saveError.contains("busy"))
        #expect(model.errorText.isEmpty)
        #expect(model.pendingMutations.isEmpty)
    }

    @MainActor @Test func changingTheConnectionEndsAPasswordManagerCheck() throws {
        let (client, _) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        var draft = MCPDraft(serverID: "", name: "Example", url: "https://mcp.example")
        draft.token.use(.onePassword)
        draft.token.reference = "op://vault/item/field"
        model.mcpDraft = draft
        model.saveMCP()
        #expect(model.isCheckingMCP)

        model.applyConnection(client)
        #expect(!model.isCheckingMCP)
    }

    @MainActor @Test func aConnectionFinishingAfterSignOutIsDropped() async throws {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        model.serverURL = client.baseURL
        model.token = "made-up-token"
        await controller.hold("/v1/agents")
        model.saveSettings()
        #expect(await controller.waitForHeld("/v1/agents"))

        // What sign-out does, without touching this machine's Keychain.
        model.token = ""
        model.applyConnection(APIClient(baseURL: client.baseURL, token: "", session: client.session))
        await controller.release("/v1/agents", body: "[]")
        while model.savingConnection { try await Task.sleep(for: .milliseconds(5)) }

        #expect(model.token.isEmpty)
        #expect(model.client?.token.isEmpty == true)
        #expect(model.notice.isEmpty)
    }
}

private func agentJSON(avatar: BotAvatarDefinition) throws -> String {
    let encoded = try #require(String(data: JSONEncoder().encode(avatar), encoding: .utf8))
    return agentFixture(#"{"id":"a1","avatar":\#(encoded)}"#)
}
