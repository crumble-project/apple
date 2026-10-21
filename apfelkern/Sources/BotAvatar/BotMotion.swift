import SwiftUI

struct BotBlend {
  var idle = 1.0
  var working = 0.0
  var sleeping = 0.0

  init(state: BotState = .idle) {
    idle = state == .idle ? 1 : 0
    working = state == .working ? 1 : 0
    sleeping = state == .sleeping ? 1 : 0
  }

  func mixed(with target: BotBlend, amount: Double) -> BotBlend {
    var result = self
    result.idle += (target.idle - idle) * amount
    result.working += (target.working - working) * amount
    result.sleeping += (target.sleeping - sleeping) * amount
    return result
  }

  func pose(at time: Double, hash: UInt64, attention: BotAttention) -> BotPose {
    let local = time + Double(hash % 10_000) / 1000
    if sleeping == 1 { return .sleeping(at: local) }
    let workTime = local * (0.92 + Double(hash % 17) / 100)
    if working == 1 { return .working(at: workTime) }
    let rest = idle > 0
      ? BotPose.idle(at: time, hash: hash).watching(attention.point, pull: attention.amount(at: time)) : .rest
    if idle == 1 { return rest }
    let work = working > 0 ? BotPose.working(at: workTime) : .rest
    let sleep = sleeping > 0 ? BotPose.sleeping(at: local) : .rest
    return BotPose(
      gazeX: rest.gazeX * idle + work.gazeX * working + sleep.gazeX * sleeping,
      gazeY: rest.gazeY * idle + work.gazeY * working + sleep.gazeY * sleeping,
      roll: rest.roll * idle + work.roll * working + sleep.roll * sleeping,
      lid: rest.lid * idle + work.lid * working + sleep.lid * sleeping,
      lift: rest.lift * idle + work.lift * working + sleep.lift * sleeping,
      scaleX: rest.scaleX * idle + work.scaleX * working + sleep.scaleX * sleeping,
      scaleY: rest.scaleY * idle + work.scaleY * working + sleep.scaleY * sleeping,
      mouthOpen: rest.mouthOpen * idle + work.mouthOpen * working + sleep.mouthOpen * sleeping,
      sway: rest.sway * idle + work.sway * working + sleep.sway * sleeping,
      glow: rest.glow * idle + work.glow * working + sleep.glow * sleeping)
  }
}

struct BotMotion {
  var from = BotBlend()
  var target = BotBlend()
  var since = Date.distantPast.timeIntervalSinceReferenceDate
  var duration = 0.6

  func blend(at time: Double) -> BotBlend {
    let progress = min(1, max(0, (time - since) / duration))
    return from.mixed(with: target, amount: progress * progress * (3 - 2 * progress))
  }

  mutating func move(to state: BotState, at time: Double, immediately: Bool = false) {
    from = immediately ? BotBlend(state: state) : blend(at: time)
    target = BotBlend(state: state)
    since = time
    duration = state == .sleeping ? 0.95 : 0.55
  }
}

extension BotPose {
  func greeting(at elapsed: Double) -> BotPose {
    guard elapsed >= 0, elapsed < 0.9 else { return self }
    let progress = elapsed / 0.9
    let envelope = pow(sin(progress * .pi), 2)
    var pose = self
    pose.lift += 0.035 * envelope
    pose.roll += sin(progress * .pi * 2) * 4 * envelope
    pose.scaleX -= 0.02 * envelope
    pose.scaleY += 0.03 * envelope
    pose.sway -= sin(progress * .pi * 2 - 0.5) * 7 * envelope
    pose.glow = max(glow, envelope)
    return pose
  }
}

struct BotLiveFrame: View {
  let look: BotLook
  let size: CGFloat
  let time: Double
  let blend: BotBlend
  let attention: BotAttention
  let reactionTime: Double

  var body: some View {
    let elapsed = time - reactionTime
    let greeting = elapsed >= 0 && elapsed < 0.9 ? pow(sin(elapsed / 0.9 * .pi), 2) : 0
    let pull = attention.amount(at: time)
    let pose = blend.pose(at: time, hash: look.hash, attention: attention)
      .greeting(at: elapsed)
    BotCanvas(
      look: look, size: size, pose: pose, expression: .calm,
      expressions: [
        (.calm, blend.idle * (1 - greeting) * (1 - pull)),
        (.delighted, (1 - blend.sleeping) * greeting + blend.idle * pull * (1 - greeting)),
        (.focused, blend.working * (1 - greeting)),
        (.asleep, blend.sleeping)
      ])
      .overlay {
        if blend.sleeping > 0 {
          SleepZs(size: size, time: time + Double(look.hash % 1000) / 1000)
            .opacity(blend.sleeping)
        }
      }
  }
}
