import apfelkern

extension APIClient {
    func activityFeed() async throws -> ActivityFeed {
        try await call("GET", "/v1/activity/feed")
    }
}
