import apfelkern

extension APIClient {
    func activityFeed() async throws -> ActivityFeedResponse {
        try await call("GET", "/v1/activity/feed")
    }
}
