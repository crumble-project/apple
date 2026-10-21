import apfelkern
import Foundation
import Testing
import UserNotifications

@testable import Crumble

/// Serves notification-suite requests apart from the shared stub, since suites can run concurrently.
final class NotificationStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var paths: [String] = []
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url?.path ?? "")
        let (status, body) = Self.handler?(request) ?? (404, "")
        Self.lock.unlock()
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func recordedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func client(_ handler: @escaping (URLRequest) -> (Int, String)) -> APIClient {
        lock.lock()
        self.handler = handler
        paths = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationStubProtocol.self]
        return APIClient(
            baseURL: "http://notify.test", token: "", session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
@MainActor
struct NotificationTests {
    private final class Posted {
        var requests: [UNNotificationRequest] = []
        var windowOnScreen = false
    }

    private func notifier(_ posted: Posted, enabled: Bool = true) throws -> Notifier {
        let defaults = try #require(UserDefaults(suiteName: "notification-tests-\(UUID().uuidString)"))
        defaults.set(enabled, forKey: "push-enabled")
        return Notifier(
            defaults: defaults, canDeliver: true, deliver: { posted.requests.append($0) },
            permission: { true }, windowOnScreen: { posted.windowOnScreen })
    }

    private func reply(_ eventID: String?, agent: String = "a1", origin: String = "owner") -> ActivityEvent {
        ActivityEvent(
            eventId: eventID, serverId: "", type: "reply", agentId: agent, agentName: "Atlas",
            origin: origin, preview: "Done")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func ledgerDeduplicatesByServerAndIsBounded() {
        var ledger = NotificationLedger()
        let inserted = [
            ledger.insert(server: "http://a", event: "e1"), ledger.insert(server: "http://a", event: "e1"),
            ledger.insert(server: "http://b", event: "e1")
        ]
        #expect(inserted == [true, false, true])
        for index in 0..<600 { _ = ledger.insert(server: "http://a", event: "n\(index)") }
        #expect(ledger.keys.count == 512)
        let evicted = ledger.insert(server: "http://a", event: "e1")
        #expect(evicted)
    }

    @Test func repeatedReplyEventPostsOnceAndSurvivesRelaunch() throws {
        let posted = Posted()
        let defaults = try #require(UserDefaults(suiteName: "notification-tests-\(UUID().uuidString)"))
        let first = Notifier(defaults: defaults, canDeliver: true, deliver: { posted.requests.append($0) })
        first.post(reply("e1"), title: "Atlas", body: "Done", serverURL: "http://a")
        first.post(reply("e1"), title: "Atlas", body: "Done", serverURL: "http://a")
        first.post(reply("e1"), title: "Atlas", body: "Done", serverURL: "http://b")
        let relaunched = Notifier(defaults: defaults, canDeliver: true, deliver: { posted.requests.append($0) })
        relaunched.post(reply("e1"), title: "Atlas", body: "Done", serverURL: "http://a")
        #expect(posted.requests.count == 2)
        #expect(posted.requests.map(\.identifier) == ["reply-http://a-a1", "reply-http://b-a1"])
        #expect(posted.requests.first?.content.userInfo["serverURL"] as? String == "http://a")
    }

    @Test func disabledNotificationsAndUnbundledBuildsPostNothing() throws {
        let posted = Posted()
        try notifier(posted, enabled: false).post(reply("e1"), title: "Atlas", body: "Done", serverURL: "http://a")
        Notifier(canDeliver: false, deliver: { posted.requests.append($0) })
            .post(reply("e2"), title: "Atlas", body: "Done", serverURL: "http://a")
        #expect(posted.requests.isEmpty)
    }

    @Test func botOriginAndVisibleChatStayQuietButHiddenWindowNotifies() throws {
        let posted = Posted()
        let model = AppModel(client: APIClient(baseURL: "http://notify.test", token: ""))
        model.notifier = try notifier(posted)
        model.route = .agent("a1")
        posted.windowOnScreen = true
        model.handleActivity(reply("delegated", origin: "bot"))
        let target = NotificationTarget(serverURL: "http://notify.test", agentId: "a1")
        model.notifier.start(model: model)
        #expect(!model.notifier.shouldPresent(target))
        posted.windowOnScreen = false
        #expect(model.notifier.shouldPresent(target))
        #expect(!model.notifier.shouldPresent(NotificationTarget(serverURL: "http://other.test", agentId: "a1")))
        model.notifier.enabled = false
        #expect(!model.notifier.shouldPresent(target))
        #expect(posted.requests.isEmpty)
    }

    @Test func clickOpensChatOnItsServerAndReportsOtherServers() throws {
        let posted = Posted()
        let client = NotificationStubProtocol.client { request in
            request.url?.path == "/v1/agents/a1/chat" ? (200, chatFixture("a1")) : (404, "")
        }
        let model = AppModel(client: client)
        model.agents = [Agent(id: "a1", name: "Atlas")]
        let notifier = try notifier(posted)
        notifier.open(NotificationTarget(serverURL: "http://notify.test", agentId: "a1"))
        #expect(model.selectedAgentID.isEmpty)
        notifier.start(model: model)
        #expect(model.selectedAgentID == "a1")

        notifier.open(NotificationTarget(serverURL: "http://other.test", agentId: "a2"))
        #expect(model.selectedAgentID == "a1")
        #expect(model.errorText.contains("http://other.test"))
    }

    @Test func clickOnDeletedBotReportsItWithoutChangingTheChat() async throws {
        let posted = Posted()
        let client = NotificationStubProtocol.client { request in
            request.url?.path == "/v1/agents" ? (200, agentFixture(#"[{"id":"a1"}]"#)) : (404, "")
        }
        let model = AppModel(client: client)
        let notifier = try notifier(posted)
        notifier.start(model: model)
        notifier.open(NotificationTarget(serverURL: "http://notify.test", agentId: "gone"))
        #expect(await waitUntil { model.errorText == "The bot for this notification no longer exists." })
        #expect(model.selectedAgentID.isEmpty)
        #expect(!NotificationStubProtocol.recordedPaths().contains("/v1/agents/gone/chat"))
    }

    @Test func startRemovesRetiredPushStateButKeepsSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "notification-tests-\(UUID().uuidString)"))
        defaults.set(false, forKey: "push-enabled")
        defaults.set(["http://a:e1"], forKey: "push-seen-events")
        for key in ["push-installation-id", "push-remote-server-url", "push-remote-server-id"] {
            defaults.set("old", forKey: key)
        }
        let notifier = Notifier(defaults: defaults, canDeliver: true, deliver: { _ in }, permission: { true })
        notifier.start(model: AppModel(client: APIClient(baseURL: "http://notify.test", token: "")))
        #expect(defaults.string(forKey: "push-installation-id") == nil)
        #expect(defaults.string(forKey: "push-remote-server-url") == nil)
        #expect(defaults.string(forKey: "push-remote-server-id") == nil)
        #expect(!notifier.enabled)
        #expect(defaults.stringArray(forKey: "push-seen-events") == ["http://a:e1"])
    }

    @Test func networkPathReconnectsOnlyWhenItReturnsOrMoves() {
        let wifi = NetworkPathState(satisfied: true, interfaces: ["en0"])
        let offline = NetworkPathState(satisfied: false, interfaces: [])
        #expect(!NetworkPathState.shouldReconnect(from: nil, to: wifi))
        #expect(!NetworkPathState.shouldReconnect(from: wifi, to: wifi))
        #expect(!NetworkPathState.shouldReconnect(from: wifi, to: offline))
        #expect(NetworkPathState.shouldReconnect(from: offline, to: wifi))
        let ethernet = NetworkPathState(satisfied: true, interfaces: ["en1"])
        #expect(NetworkPathState.shouldReconnect(from: wifi, to: ethernet))
    }

    @Test func activityReconnectReloadsBotsMissedWhileDisconnected() async throws {
        let preview = #"{"type":"chat-preview","agentId":"a1","agentName":"Atlas","lastMessage":"Hi"}"#
        let client = NotificationStubProtocol.client { request in
            switch request.url?.path {
            case "/v1/events": (200, "event: activity\ndata: \(preview)\n\n")
            case "/v1/agents": (200, agentFixture(#"[{"id":"a1"},{"id":"a2","name":"Beacon"}]"#))
            default: (404, "")
            }
        }
        let model = AppModel(client: client)
        model.notifier = try notifier(Posted())
        model.agents = [Agent(id: "a1", name: "Atlas")]
        model.followActivity()
        defer { model.activityTask?.cancel() }
        #expect(await waitUntil { model.agents.map(\.id) == ["a1", "a2"] })
        let paths = NotificationStubProtocol.recordedPaths()
        let firstAgents = try #require(paths.firstIndex(of: "/v1/agents"))
        #expect(paths.prefix(firstAgents).filter { $0 == "/v1/events" }.count >= 2)
    }

    @Test func jobAnswersNameTheirJob() {
        let away = NotificationContext(windowOnScreen: false, route: nil)
        var answer = ActivityEvent(
            type: "reply", agentId: "a1", agentName: "Desk", origin: "desktop", preview: "Logged in?",
            jobName: "github")
        #expect(notification(for: answer, in: away)?.title == "Desk · desktop job github")
        answer.jobName = nil
        #expect(notification(for: answer, in: away)?.title == "Desk · desktop job")
        answer.origin = "coding"
        answer.jobName = "fix-ci"
        #expect(notification(for: answer, in: away)?.title == "Desk · coding job fix-ci")
    }

    @Test func aDesktopJobNotificationOpensTheChatAndItsBotDesktop() throws {
        let posted = Posted()
        let client = NotificationStubProtocol.client { request in
            request.url?.path == "/v1/agents/a1/chat" ? (200, chatFixture("a1")) : (404, "")
        }
        let model = AppModel(client: client)
        model.agents = [Agent(id: "a1", name: "Desk")]
        let notifier = try notifier(posted)
        var desktops: [String] = []
        notifier.openBotDesktop = { desktops.append($0) }
        notifier.start(model: model)

        notifier.post(reply("e1", origin: "desktop"), title: "Desk", body: "Done", serverURL: "http://notify.test")
        notifier.post(reply("e2", origin: "coding"), title: "Desk", body: "Done", serverURL: "http://notify.test")
        let targets = posted.requests.compactMap { Notifier.target($0.content.userInfo) }
        #expect(targets.map(\.desktop) == [true, false])

        notifier.open(targets[1])
        #expect(desktops.isEmpty)
        notifier.open(targets[0])
        #expect(model.selectedAgentID == "a1")
        #expect(desktops == ["a1"])
    }
}
