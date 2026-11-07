import Foundation
import Testing

@testable import apfelkern

@Suite struct ComposerDraftsTests {
  private func defaults() throws -> UserDefaults {
    let name = "crumble.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func eachConversationKeepsItsOwnText() {
    var drafts = ComposerDrafts()
    drafts["a"] = "for a"
    drafts["b"] = "for b"
    #expect(drafts["a"] == "for a")
    #expect(drafts["b"] == "for b")
  }

  @Test func emptyTextClearsTheDraft() {
    var drafts = ComposerDrafts()
    drafts["a"] = "text"
    drafts["a"] = ""
    #expect(drafts["a"] == nil)
  }

  @Test func noOpenChatKeepsNothing() {
    var drafts = ComposerDrafts()
    drafts[""] = "text"
    #expect(drafts[""] == nil)
  }

  @Test func draftsSurviveALaunch() throws {
    let defaults = try defaults()
    var drafts = ComposerDrafts(defaults: defaults)
    drafts["a"] = "unsent"
    #expect(ComposerDrafts(defaults: defaults)["a"] == "unsent")
  }

  @Test func removingAllReachesStorage() throws {
    let defaults = try defaults()
    var drafts = ComposerDrafts(defaults: defaults)
    drafts["a"] = "unsent"
    drafts.removeAll()
    #expect(ComposerDrafts(defaults: defaults)["a"] == nil)
  }
}

@Suite struct ActivityFailureTests {
  private func entry(kind: String = "tool-result", _ details: [String: JSONValue]) -> ActivityEntry {
    ActivityEntry(id: "1", agentId: nil, agentName: nil, entryId: nil, kind: kind, details: details)
  }

  @Test func anErrorFlagOrDetailFails() {
    #expect(entry(["isError": .bool(true)]).failed)
    #expect(entry(["error": .string("boom")]).failed)
    #expect(entry(["error": .object([:])]).failed)
  }

  @Test func falsyDetailsPass() {
    #expect(!entry([:]).failed)
    #expect(!entry(["isError": .bool(false)]).failed)
    #expect(!entry(["error": .string("")]).failed)
    #expect(!entry(["error": .null]).failed)
  }

  @Test func aChangeNeverFails() {
    #expect(!entry(kind: "change", ["isError": .bool(true)]).failed)
  }
}

@Suite struct ModelReasoningTests {
  private let models = [
    ModelSummary(provider: "p", id: "fast", thinkingLevels: [.off]),
    ModelSummary(provider: "p", id: "deep", thinkingLevels: [.off, .high])
  ]

  @Test func aListedModelLimitsTheLevels() {
    #expect(ThinkingLevel.available(for: "deep", in: models) == [.off, .high])
    #expect(ThinkingLevel.available(for: " deep ", in: models) == [.off, .high])
  }

  @Test func anUnlistedModelOffersEveryLevel() {
    #expect(ThinkingLevel.available(for: "other", in: models) == ThinkingLevel.allCases)
    #expect(ThinkingLevel.available(for: nil, in: models) == ThinkingLevel.allCases)
  }
}
