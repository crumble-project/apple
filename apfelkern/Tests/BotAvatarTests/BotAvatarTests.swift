import Testing

@testable import BotAvatar

struct BotAvatarTests {
  @Test func workingHopSquashesOncePerLandingAndOnlyOnTheGround() {
    let samples = stride(from: 0.2, to: 1.1, by: 0.004).map { BotPose.working(at: $0) }
    let dips = samples.indices.dropFirst().dropLast().filter {
      samples[$0].scaleY < samples[$0 - 1].scaleY && samples[$0].scaleY <= samples[$0 + 1].scaleY
    }.count
    for pose in samples where pose.scaleY < 1 {
      #expect(pose.lift == 0)
    }
    #expect(dips == 1)
  }
}
