import AppKit
import Foundation
import Testing
@testable import Crumble

/// URLProtocol isolated from the other client suites; Swift Testing may run suites concurrently.
final class PushNotificationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    nonisolated(unsafe) static var asyncHandler: (@Sendable (URLRequest) async -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            stream.close(); request.httpBody = data
        }
        Self.requests.append(request)
        if let handler = Self.asyncHandler {
            let recorded = request
            Task.detached { @Sendable [self, recorded, handler] in
                let (status, body) = await handler(recorded)
                respond(status: status, body: body)
            }
        } else {
            let (status, body) = Self.handler?(request) ?? (404, "")
            respond(status: status, body: body)
        }
    }
    private func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct PushNotificationsTests {
    private let url = "http://push.test"

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushNotificationProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client(_ token: String = "secret", _ handler: @escaping (URLRequest) -> (Int, String)) -> APIClient {
        PushNotificationProtocol.asyncHandler = nil
        PushNotificationProtocol.handler = handler
        PushNotificationProtocol.requests = []
        return APIClient(baseURL: url, token: token, session: session())
    }

    private func manager(
        client: APIClient,
        defaults: UserDefaults = UserDefaults(suiteName: "push-tests-\(UUID().uuidString)")!,
        removals: Reference<[PendingPushRemoval]> = Reference([])
    ) -> PushNotifications {
        PushNotifications(defaults: defaults, environment: "development", bundleId: "com.example.test",
                          loadRemovals: { removals.value }, saveRemovals: { removals.value = $0 },
                          makeClient: { base, token in APIClient(baseURL: base, token: token, session: client.session) },
                          permission: { true })
    }

    @Test func APIClientEncodesRegistrationAndNullPresenceAgent() async throws {
        let client = client { request in
            let path = request.url?.path ?? ""
            if path == "/v1/push" { return (200, #"{"serverId":"srv","transports":{"apns":true}}"#) }
            if path.hasPrefix("/v1/push/devices/") { return (200, #"{"serverId":"srv","remoteDelivery":true}"#) }
            return (204, "")
        }
        _ = try await client.pushStatus()
        _ = try await client.registerPush("i", device: PushDevice(token: "aa", environment: "development", bundleId: "b"))
        try await client.pushPresence("i", active: false, agentId: nil)
        let presence = PushNotificationProtocol.requests.first { $0.url?.path.contains("presence") == true }
        let presenceBody = String(decoding: presence?.httpBody ?? Data(), as: UTF8.self)
        #expect(presenceBody.contains(#""agentId":null"#))
    }

    @Test func remoteRegistrationSuppressesLocalFallbackAnd404KeepsIt() async throws {
        let client = client { request in
            let path = request.url?.path ?? ""
            if path == "/v1/push" { return (200, #"{"serverId":"srv","transports":{"apns":true}}"#) }
            if path.hasPrefix("/v1/push/devices/") { return (200, #"{"serverId":"srv","remoteDelivery":true}"#) }
            return (204, "")
        }
        let manager = manager(client: client)
        manager.receivedToken(Data([0xaa]))
        let model = AppModel(client: client); manager.start(model: model); await manager.waitForSynchronization()
        #expect(manager.remoteDelivery)
        let event = ActivityEvent(eventId: "e", serverId: "srv", createdAt: nil, type: "reply", agentId: "a", agentName: "A", entryId: nil, origin: "user", preview: "hi", lastMessage: nil)
        #expect(!manager.shouldPostLocal(event))

        let unavailable = self.client { request in request.url?.path == "/v1/push" ? (404, "") : (404, "") }
        manager.connect(unavailable); await manager.waitForSynchronization()
        #expect(!manager.remoteDelivery)
        let fallbackEvent = ActivityEvent(eventId: "e2", serverId: "srv", createdAt: nil, type: "reply", agentId: "a", agentName: "A", entryId: nil, origin: "user", preview: "hi", lastMessage: nil)
        #expect(manager.shouldPostLocal(fallbackEvent))
    }

    @Test func ledgerDeduplicatesByServerAndIsBounded() {
        var ledger = PushEventLedger()
        let first = ledger.insert(server: "a", event: "1")
        let duplicate = ledger.insert(server: "a", event: "1")
        let otherServer = ledger.insert(server: "b", event: "1")
        #expect(first)
        #expect(!duplicate)
        #expect(otherServer)
        for index in 0..<600 { _ = ledger.insert(server: "a", event: "\(index)") }
        #expect(ledger.keys.count == 512)
    }

    @Test func emptyServerEventsUseLegacyLocalFallbackAndLedgerPersists() {
        let defaults = UserDefaults(suiteName: "push-ledger-\(UUID().uuidString)")!
        let client = APIClient(baseURL: url, token: "secret", session: session())
        let first = manager(client: client, defaults: defaults)
        let legacy = ActivityEvent(eventId: "legacy", serverId: "", createdAt: nil, type: "reply", agentId: "a", agentName: "A", entryId: nil, origin: "user", preview: "hi", lastMessage: nil)
        #expect(first.shouldPostLocal(legacy))
        let scoped = ActivityEvent(eventId: "same", serverId: "srv", createdAt: nil, type: "reply", agentId: "a", agentName: "A", entryId: nil, origin: "user", preview: "hi", lastMessage: nil)
        #expect(first.shouldPostLocal(scoped))
        let second = manager(client: client, defaults: defaults)
        #expect(!second.shouldPostLocal(scoped))
    }

    @Test func validTapQueuedBeforeStartRoutesAfterIdentity() async throws {
        let client = client { request in
            request.url?.path == "/v1/push" ? (200, #"{"serverId":"srv","transports":{"apns":false}}"#) : (204, "")
        }
        let manager = manager(client: client)
        let model = AppModel(client: client)
        var opened = false
        manager.openMainWindow = { opened = true }
        manager.open(ActivityEvent(eventId: "tap", serverId: "srv", createdAt: nil, type: "reply", agentId: "a", agentName: "A", entryId: nil, origin: "user", preview: nil, lastMessage: nil))
        manager.start(model: model)
        await manager.waitForSynchronization()
        #expect(opened)
        #expect(model.route == .agent("a"))
    }

    @Test func switchingServerQueuesRemovalAndTokenRotationUsesLatestToken() async throws {
        let removals = Reference<[PendingPushRemoval]>([])
        let first = client { request in
            let path = request.url?.path ?? ""
            if path == "/v1/push" { return (200, #"{"serverId":"one","transports":{"apns":true}}"#) }
            if path.hasPrefix("/v1/push/devices/") { return (200, #"{"serverId":"one","remoteDelivery":true}"#) }
            return (204, "")
        }
        let manager = manager(client: first, removals: removals)
        manager.receivedToken(Data([1])); let model = AppModel(client: first); manager.start(model: model); await manager.waitForSynchronization()
        let second = client("new-secret") { request in request.url?.path == "/v1/push" ? (200, #"{"serverId":"two","transports":{"apns":true}}"#) : (404, "") }
        manager.connect(second); manager.receivedToken(Data([2])); await manager.waitForSynchronization()
        let methods = PushNotificationProtocol.requests.compactMap(\.httpMethod)
        #expect(methods.contains("DELETE"))
        #expect(PushNotificationProtocol.requests.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("02") })
    }

    @Test func staleRegistrationResponseCannotBindDifferentServer() async throws {
        let client = client { request in
            if request.url?.path == "/v1/push" { return (200, #"{"serverId":"identity","transports":{"apns":true}}"#) }
            return (200, #"{"serverId":"other","remoteDelivery":true}"#)
        }
        let manager = manager(client: client); manager.receivedToken(Data([1])); let model = AppModel(client: client); manager.start(model: model); await manager.waitForSynchronization()
        #expect(!manager.remoteDelivery)
    }

    @Test func coldTapWaitsForIdentityAndRejectsWrongServer() async throws {
        let client = client { _ in (200, #"{"serverId":"srv","transports":{"apns":false}}"#) }
        let manager = manager(client: client); let model = AppModel(client: client); var opened = false
        manager.openMainWindow = { opened = true }; manager.start(model: model)
        manager.open(ActivityEvent(eventId: "e", serverId: "wrong", createdAt: nil, type: "reply", agentId: "a", agentName: "A", entryId: nil, origin: "user", preview: nil, lastMessage: nil))
        await manager.waitForSynchronization(); #expect(!opened)
    }

    @Test func oldRegistrationCompletingAfterSwitchIsRemovedBeforeNewBinding() async throws {
        let gate = DeferredPushResponse()
        let networkSession = session()
        let old = APIClient(baseURL: "http://old.push.test", token: "old-secret", session: networkSession)
        let new = APIClient(baseURL: "http://new.push.test", token: "new-secret", session: networkSession)
        PushNotificationProtocol.requests = []
        PushNotificationProtocol.asyncHandler = { request in
            let host = request.url!.host!
            if host == "old.push.test", request.httpMethod == "PUT", !request.url!.path.hasSuffix("presence") {
                return await gate.response()
            }
            if request.url!.path == "/v1/push" {
                return (200, "{\"serverId\":\"\(host)\",\"transports\":{\"apns\":true}}")
            }
            if request.httpMethod == "PUT", !request.url!.path.hasSuffix("presence") {
                return (200, "{\"serverId\":\"\(host)\",\"remoteDelivery\":true}")
            }
            return (204, "")
        }
        defer { PushNotificationProtocol.asyncHandler = nil }
        let manager = manager(client: old)
        manager.receivedToken(Data([0xab]))
        manager.connect(old)
        await gate.waitUntilRequested()
        manager.connect(new)
        await gate.release(status: 200, body: #"{"serverId":"old.push.test","remoteDelivery":true}"#)
        await manager.waitForSynchronization()
        #expect(manager.serverId == "new.push.test")
        #expect(manager.remoteDelivery)
        let deletions = PushNotificationProtocol.requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletions.contains { $0.url?.host == "old.push.test" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer old-secret" })
        #expect(!deletions.contains { $0.url?.host == "new.push.test" })
    }

    @Test func removalSurvivesRestartAndRetriesUsingOldCredentials() async throws {
        let saved = Reference<[PendingPushRemoval]>([])
        let defaults = UserDefaults(suiteName: "push-removal-\(UUID().uuidString)")!
        let failed = client("old-secret") { _ in (503, "offline") }
        let first = manager(client: failed, defaults: defaults, removals: saved)
        first.connect(failed)
        first.enabled = false
        await first.waitForSynchronization()
        #expect(saved.value == [PendingPushRemoval(baseURL: url, token: "old-secret")])
        let restored = client("new-secret") { request in
            request.httpMethod == "DELETE" ? (204, "") : (404, "")
        }
        let second = manager(client: restored, defaults: defaults, removals: saved)
        second.connect(restored)
        await second.waitForSynchronization()
        #expect(saved.value.isEmpty)
        #expect(PushNotificationProtocol.requests.contains {
            $0.httpMethod == "DELETE" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer old-secret"
        })
    }

    @Test func disablingQueuesUnregistrationAndPersistsFailures() async throws {
        let removals = Reference<[PendingPushRemoval]>([])
        let client = client { _ in (503, "down") }
        let manager = manager(client: client, removals: removals); manager.connect(client); manager.enabled = false; await manager.waitForSynchronization()
        #expect(removals.value.contains { $0.baseURL == url })
    }
}

private final class Reference<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

private actor DeferredPushResponse {
    private var continuation: CheckedContinuation<(Int, String), Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func response() async -> (Int, String) {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested?.resume()
            requested = nil
        }
    }
    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func release(status: Int, body: String) {
        continuation?.resume(returning: (status, body))
        continuation = nil
    }
}
