import Foundation
import Testing

@testable import apfelkern

@Suite struct PinnedConversationsTests {
  private let all: [Route] = [.agent("1"), .agent("2"), .group("g"), .agent("3")]

  @Test func pinsKeepTheirOrderAndLeaveTheRestInTheirs() {
    let existing = Set(all)
    var pins = PinnedConversations()
    pins = pins.pinning(.agent("3"), among: existing)
    pins = pins.pinning(.group("g"), among: existing)
    let split = pins.split(all) { $0 }
    #expect(split.pinned == [.agent("3"), .group("g")])
    #expect(split.unpinned == [.agent("1"), .agent("2")])
    pins = pins.unpinning(.agent("3"), among: existing)
    #expect(!pins.contains(.agent("3")))
    #expect(pins.keys == ["group:g"])
  }

  @Test func onlySavedChatsCanBePinned() {
    let pins = PinnedConversations()
    #expect(!pins.canPin(.memory, among: [.memory]))
    #expect(!pins.canPin(.group("local:1"), among: [.group("local:1")]))
    #expect(pins.canPin(.agent("1"), among: [.agent("1")]))
  }

  @Test func nineIsTheLimitAndGoneConversationsDontCount() {
    let nine = Set((1...9).map { Route.agent("\($0)") })
    var pins = PinnedConversations()
    let existing = nine.union([.agent("10")])
    for route in nine.sorted(by: { "\($0)" < "\($1)" }) { pins = pins.pinning(route, among: existing) }
    #expect(!pins.canPin(.agent("10"), among: nine.union([.agent("10")])))
    let afterDelete = nine.subtracting([.agent("1")]).union([.agent("10")])
    #expect(pins.canPin(.agent("10"), among: afterDelete))
    pins = pins.pinning(.agent("10"), among: afterDelete)
    #expect(pins.contains(.agent("10")))
    #expect(!pins.contains(.agent("1")))
  }

  @Test func changesDropKeysForMissingConversations() {
    let pins = PinnedConversations(keys: ["agent:gone", "agent:1"])
    #expect(pins.pinning(.agent("2"), among: [.agent("1"), .agent("2")]).keys == ["agent:1", "agent:2"])
    #expect(pins.unpinning(.agent("2"), among: [.agent("1")]).keys == ["agent:1"])
  }

  @Test func aDraggedPinTakesItsTargetsPlace() {
    let existing = Set(all)
    let pins = PinnedConversations(keys: ["agent:1", "agent:2", "agent:3"])
    let moved = pins.moving(.agent("3"), to: .agent("1"), among: existing)
    #expect(moved.keys == ["agent:3", "agent:1", "agent:2"])
    #expect(moved.moving(.agent("3"), to: .agent("2"), among: existing).keys == ["agent:1", "agent:2", "agent:3"])
  }

  @Test func keysRoundTrip() {
    for route in [Route.agent("a:b"), .group("g")] {
      #expect(PinnedConversations.key(route).flatMap(PinnedConversations.route(key:)) == route)
    }
    #expect(PinnedConversations.route(key: "memory:x") == nil)
  }
}
