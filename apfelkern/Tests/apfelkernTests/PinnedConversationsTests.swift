import Foundation
import Testing

@testable import apfelkern

@Suite struct PinnedConversationsTests {
  private func defaults() throws -> UserDefaults {
    let name = "PinnedConversationsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func pinsKeepTheirOrderAndLeaveTheRestInTheirs() {
    var pins = PinnedConversations(server: "https://a")
    let all: [Route] = [.agent("1"), .agent("2"), .group("g"), .agent("3")]
    pins.pin(.agent("3"), among: Set(all))
    pins.pin(.group("g"), among: Set(all))
    let split = pins.split(all) { $0 }
    #expect(split.pinned == [.agent("3"), .group("g")])
    #expect(split.unpinned == [.agent("1"), .agent("2")])
    pins.unpin(.agent("3"))
    #expect(!pins.contains(.agent("3")))
    #expect(pins.split(all) { $0 }.pinned == [.group("g")])
  }

  @Test func onlySavedChatsCanBePinned() {
    let pins = PinnedConversations(server: "https://a")
    #expect(!pins.canPin(.memory, among: [.memory]))
    #expect(!pins.canPin(.group("local:1"), among: [.group("local:1")]))
    #expect(pins.canPin(.agent("1"), among: [.agent("1")]))
  }

  @Test func nineIsTheLimitAndGoneConversationsDontCount() {
    var pins = PinnedConversations(server: "https://a")
    let nine = Set((1...9).map { Route.agent("\($0)") })
    for route in nine { pins.pin(route, among: nine.union([.agent("10")])) }
    #expect(!pins.canPin(.agent("10"), among: nine.union([.agent("10")])))
    let afterDelete = nine.subtracting([.agent("1")]).union([.agent("10")])
    #expect(pins.canPin(.agent("10"), among: afterDelete))
    pins.pin(.agent("10"), among: afterDelete)
    #expect(pins.contains(.agent("10")))
    #expect(!pins.contains(.agent("1")))
  }

  @Test func pinsAreSavedPerServer() throws {
    let store = try defaults()
    var pins = PinnedConversations(server: "https://a", defaults: store)
    pins.pin(.agent("1"), among: [.agent("1")])
    #expect(PinnedConversations(server: "https://a", defaults: store).contains(.agent("1")))
    #expect(!PinnedConversations(server: "https://b", defaults: store).contains(.agent("1")))
  }
}

@Suite struct PinnedConversationMoveTests {
  @Test func aDraggedPinTakesItsTargetsPlace() {
    var pins = PinnedConversations(server: "https://a")
    let all: [Route] = [.agent("1"), .agent("2"), .agent("3")]
    for route in all { pins.pin(route, among: Set(all)) }
    pins.move(.agent("3"), to: .agent("1"))
    #expect(pins.split(all) { $0 }.pinned == [.agent("3"), .agent("1"), .agent("2")])
    pins.move(.agent("3"), to: .agent("2"))
    #expect(pins.split(all) { $0 }.pinned == [.agent("1"), .agent("2"), .agent("3")])
  }

  @Test func keysRoundTrip() {
    for route in [Route.agent("a:b"), .group("g")] {
      #expect(PinnedConversations.key(route).flatMap(PinnedConversations.route(key:)) == route)
    }
    #expect(PinnedConversations.route(key: "memory:x") == nil)
  }
}
