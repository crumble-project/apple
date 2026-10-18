import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor @Test func memoryCreateAppearsBeforeServerResponseAndReconciles() async throws {
        let client = StubProtocol.client { request in
            if request.httpMethod == "POST", request.url?.path == "/v1/memories" {
                return (200, #"{"id":"m1","content":"Remember this"}"#)
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
}
