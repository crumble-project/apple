import apfelkern
import Foundation

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
