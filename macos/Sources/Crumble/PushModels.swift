import Foundation

struct PushStatus: Codable, Sendable {
    var serverId: String
    var transports: [String: Bool]
}
struct PushRegistration: Codable, Sendable {
    var serverId: String
    var remoteDelivery: Bool
}
struct PushDevice: Encodable, Sendable {
    var platform = "macos"
    var transport = "apns"
    var token: String
    var environment: String
    var bundleId: String
    var enabled = true
}

extension APIClient {
    func pushStatus() async throws -> PushStatus { try await call("GET", "/v1/push") }
    func registerPush(_ id: String, device: PushDevice) async throws -> PushRegistration {
        try await call("PUT", "/v1/push/devices/\(id)", body: device)
    }
    func unregisterPush(_ id: String) async throws { _ = try await send("DELETE", "/v1/push/devices/\(id)") }
    func pushPresence(_ id: String, active: Bool, agentId: String?, timeout: TimeInterval = 20) async throws {
        struct Presence: Encodable {
            var active: Bool
            var agentId: JSONValue
        }
        _ = try await send(
            "PUT", "/v1/push/devices/\(id)/presence",
            body: Presence(active: active, agentId: agentId.map(JSONValue.string) ?? .null), timeout: timeout)
    }
}

/// A bounded, persisted ledger shared by stream fallback and foreground APNs delivery.
struct PushEventLedger {
    var keys: [String] = []
    mutating func insert(server: String, event: String) -> Bool {
        let key = server + ":" + event
        guard !keys.contains(key) else { return false }
        keys.append(key)
        if keys.count > 512 { keys.removeFirst(keys.count - 512) }
        return true
    }
}

struct PendingPushRemoval: Codable, Equatable {
    var baseURL: String
    var token: String
}
