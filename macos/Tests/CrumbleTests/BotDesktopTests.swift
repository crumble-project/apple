import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    private static let owner = #"{"holder":"owner","changes":1,"updatedAt":"now"}"#

    @MainActor private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor @Test func takingControlStaysPendingUntilTheServerConfirms() async {
        let session = BotDesktopSession(agentID: "a1", client: StubProtocol.client { request in
            request.httpMethod == "PUT" ? (200, Self.owner) : (404, "")
        })

        session.take()

        #expect(session.pending == .owner)
        #expect(session.holder == .bot)
        await eventually { session.pending == nil }
        #expect(session.holder == .owner)
        #expect(session.error.isEmpty)
    }

    @MainActor @Test func aFailedTakeLeavesTheBotInControlAndSaysWhy() async {
        let session = BotDesktopSession(agentID: "a1", client: StubProtocol.client { request in
            request.httpMethod == "PUT" ? (409, #"{"error":"This bot has no bot desktop"}"#) : (404, "")
        })

        session.take()
        await eventually { session.pending == nil }

        #expect(session.holder == .bot)
        #expect(!session.error.isEmpty)
    }

    @MainActor @Test func controlChangedElsewhereShowsUp() async {
        let session = BotDesktopSession(agentID: "a1", client: StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/agents/a1/desktop/events": (200, "event: control\ndata: \(Self.owner)\n\n")
            case "/v1/agents/a1/desktop/viewer": (201, #"{"path":"/desktop-viewer/one","expiresAt":"soon"}"#)
            default: (404, "")
            }
        })

        session.connect()
        await eventually { session.holder == .owner && session.link != nil }
        #expect(session.holder == .owner)
        #expect(session.link?.path.hasSuffix("/desktop-viewer/one") == true)
        session.close()
    }

    @MainActor @Test func reconnectingAsksForANewSingleUseLink() async {
        nonisolated(unsafe) var issued = 0
        let session = BotDesktopSession(agentID: "a1", client: StubProtocol.client { request in
            guard request.url?.path == "/v1/agents/a1/desktop/viewer" else { return (404, "") }
            issued += 1
            return (201, #"{"path":"/desktop-viewer/t\#(issued)","expiresAt":"soon"}"#)
        })

        session.reconnect()
        await eventually { session.link != nil }
        let first = session.link
        session.reconnect()
        await eventually { session.link != first }

        #expect(issued == 2)
        #expect(session.link?.path.hasSuffix("/desktop-viewer/t2") == true)
    }

    @Test func handingBackIsOfferedOnlyToTheOwner() {
        #expect(BotDesktopSession.action(for: .bot, pending: nil) == .take)
        #expect(BotDesktopSession.action(for: .owner, pending: nil) == .handBack)
        #expect(BotDesktopSession.action(for: .bot, pending: .owner) == .waiting)
    }
}
