import Foundation
import apfelkern

struct ActivityRecord: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var agentId: String
  var agentName: String
  var entryId: String
  var timestamp: Int64?
  var kind: String
  var details: JSONValue
}

struct ActivityFeed: Codable, Sendable {
  var activities: [ActivityRecord]
  var hasMore: Bool
}
