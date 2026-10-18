import Foundation
import apfelkern

struct ActivityFeedResponse: Codable, Sendable {
    var activities: [ActivityEntry]
    var hasMore: Bool
}

struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var agentId: String
    var agentName: String
    var entryId: String
    var timestamp: Int64?
    var kind: String
    var details: [String: JSONValue]
}
