import SwiftUI

// Bot avatars grow from Hermex's drawn faces (MIT, see THIRD_PARTY_NOTICES.md): a shaded shape in
// one color with two leaning capsule eyes, a mouth, cheeks and a little topper. The seed picks them all.

public enum BotState: Sendable { case idle, working, sleeping }

public enum BotShape: CaseIterable, Sendable { case circle, squircle, pill, triangle, hexagon, cloud, drop }

enum BotMouth: CaseIterable, Sendable { case smile, grin, cat, tiny }

enum BotTopper: CaseIterable, Sendable { case none, antenna, sprout, tuft }

public struct BotLook: Equatable, Sendable {
  public static let palette = [
    "#8b5cf6", "#38bdf8", "#14b8a6", "#22c55e", "#f59e0b", "#f97316", "#ef4444", "#ec4899"
  ]

  public let shape: BotShape
  public let hex: String
  public let hash: UInt64
  let mouth: BotMouth
  let topper: BotTopper
  public var finish = BotFinish.glossy

  /// The same bot with another finish.
  init(_ look: BotLook, finish: BotFinish) {
    self = look
    self.finish = finish
  }

  public init(seed: String, finish: BotFinish = .glossy) {
    self.finish = finish
    hash = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    shape = BotShape.allCases[Int(hash % UInt64(BotShape.allCases.count))]
    hex = Self.palette[Int(hash % UInt64(Self.palette.count))]
    mouth = BotMouth.allCases[Int((hash >> 16) % UInt64(BotMouth.allCases.count))]
    topper = BotTopper.allCases[Int((hash >> 24) % UInt64(BotTopper.allCases.count))]
  }

  struct RGB {
    let red: Double
    let green: Double
    let blue: Double
  }

  var rgb: RGB {
    let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
    return RGB(
      red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
      blue: Double(value & 0xff) / 255)
  }

  var color: Color { tint(0) }

  /// The body color moved toward white for positive amounts and toward black for negative ones.
  func tint(_ amount: Double) -> Color {
    let components = rgb
    let target = amount > 0 ? 1.0 : 0.0
    let mix = abs(amount)
    return Color(
      red: components.red + (target - components.red) * mix,
      green: components.green + (target - components.green) * mix,
      blue: components.blue + (target - components.blue) * mix)
  }

  var inkColor: Color { tint(-0.8) }

  /// Pink cheeks vanish on warm bodies, so those blush white instead.
  var blushColor: Color {
    ["#ef4444", "#ec4899", "#f97316", "#f59e0b"].contains(hex)
      ? .white.opacity(0.5) : Color(red: 1, green: 0.42, blue: 0.6).opacity(0.55)
  }
}

/// How the face reads, apart from its motion.
enum BotExpression { case calm, delighted, focused, asleep }

/// One frame of a face: gaze as a fraction of the size, roll in degrees, the lid factor, a lift
/// as a fraction of the size, the squash and stretch of the body anchored at its base, how far the
/// mouth opens, the topper's lag in degrees and the antenna's glow.
struct BotPose: Equatable {
  var gazeX = 0.0
  var gazeY = 0.0
  var roll = 0.0
  var lid = 1.0
  var lift = 0.0
  var scaleX = 1.0
  var scaleY = 1.0
  var mouthOpen = 0.0
  var sway = 0.0
  var glow = 0.0

  static let rest = BotPose()
  static let shutLid = 0.06
  /// Every rhythm in a state repeats a whole number of times per loop, so the layer-driven
  /// avatar can play each state as one seamless keyframe loop.
  static let idleLoop = 36.0
  static let workingLoop = 25.2
  static let sleepingLoop = 16.0

  /// The loop length of a state, in seconds.
  static func loop(_ state: BotState) -> Double {
    switch state {
    case .idle: idleLoop
    case .working: workingLoop
    case .sleeping: sleepingLoop
    }
  }

  /// The angular speed that repeats `count` times per loop.
  private static func rate(_ count: Double, in loop: Double) -> Double { 2 * .pi * count / loop }

  /// A period close to `period` that divides the loop evenly, and how many times it fits.
  private static func snap(_ period: Double, to loop: Double) -> (period: Double, count: Int) {
    let count = max(1, (loop / period).rounded())
    return (loop / count, Int(count))
  }

  /// Breathes, rocks a little, glances around and blinks, sometimes twice.
  static func idle(at time: Double, hash: UInt64) -> BotPose {
    let local = time + Double(hash % 10_000) / 1000
    let breath = sin(local * rate(10, in: idleLoop))
    let roll = sin(local * rate(3, in: idleLoop)) * 2.2
    let gaze = glance(at: local, hash: hash)
    let stretchPhase = positive(local, modulo: hash.isMultiple(of: 2) ? 12 : 18)
    let stretch = stretchPhase < 1.8 ? pow(sin(stretchPhase / 1.8 * .pi), 4) : 0
    return BotPose(
      gazeX: gaze.x, gazeY: gaze.y, roll: roll, lid: blink(at: local, hash: hash), lift: 0.006 * (breath + 1),
      scaleX: 1 - 0.012 * breath - 0.035 * stretch,
      scaleY: 1 + 0.022 * breath + 0.055 * stretch,
      sway: -roll * 1.6 + sin(local * rate(8, in: idleLoop)) * 3 + stretch * 7)
  }

  /// Leans aside and sways as Hermex's working face does, hopping on the spot as it goes:
  /// each landing is one squash on the ground that springs into the next jump, and its topper
  /// swings once per hop.
  static func working(at time: Double) -> BotPose {
    let loop = workingLoop
    let turn = -11 + sin(time * rate(2, in: loop)) * 8
    let tilt = sin(time * rate(2, in: loop) + 1.3) * 8 + sin(time * rate(4, in: loop)) * 1.6
    let blinkPeriod = loop / 17
    let blink = positive(time, modulo: blinkPeriod) > blinkPeriod * 0.869
    let hop = positive(time, modulo: 0.9) / 0.9
    let ground = 0.12
    let contact = min(hop, 1 - hop)
    let squash = contact < ground ? 1 - 0.055 * cos(contact / ground * .pi / 2) : 1
    let air = contact < ground ? 0 : (hop - ground) / (1 - 2 * ground)
    return BotPose(
      gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: sin(time * rate(3, in: loop)) * 4.2,
      lid: blink ? shutLid : 1, lift: 0.04 * sin(air * .pi), scaleX: 2 - squash, scaleY: squash,
      mouthOpen: 0.5 + 0.5 * sin(time * rate(18, in: loop)),
      sway: -sin(air * 2 * .pi) * 9 - sin(time * rate(3, in: loop)) * 4,
      glow: 0.55 + 0.45 * sin(time * rate(20, in: loop)))
  }

  /// Breathes slowly with the head dropped a little and the mouth rising and falling.
  static func sleeping(at time: Double) -> BotPose {
    let breath = sin(time * rate(4, in: sleepingLoop))
    return BotPose(
      gazeY: 0.03, roll: -5 + sin(time * rate(1, in: sleepingLoop)) * 1.5, lid: shutLid,
      scaleX: 1 - 0.02 * breath, scaleY: 1 + 0.035 * breath,
      mouthOpen: 0.5 + 0.5 * breath, sway: 6 + breath * 3)
  }

  /// Blinks for 180 ms every 3 to 5 seconds, seeded so faces never blink together; every third
  /// blink is a double.
  static func blink(at time: Double, hash: UInt64) -> Double {
    let (period, count) = snap(3 + Double(hash % 2001) / 1000, to: idleLoop)
    let cycle = floor(time / period)
    let offset = time - cycle * period
    let shut = 0.18
    let closed = { (moment: Double) in 1 - (1 - shutLid) * sin(moment / shut * .pi) }
    if offset < shut { return closed(offset) }
    let double = mix(hash, wrap(cycle, count)) % 3 == 0
    if double, offset > 0.28, offset < 0.28 + shut { return closed(offset - 0.28) }
    return 1
  }

  /// Holds a gaze for two to three and a half seconds, then darts to the next one.
  static func glance(at time: Double, hash: UInt64) -> (x: Double, y: Double) {
    let (hold, count) = snap(2 + Double((hash >> 8) % 1500) / 1000, to: idleLoop)
    let step = floor(time / hold)
    let into = (time - step * hold) / 0.14
    let ease = into >= 1 ? 1 : into * into * (3 - 2 * into)
    let from = target(hash, wrap(step - 1, count))
    let next = target(hash, wrap(step, count))
    return (from.x + (next.x - from.x) * ease, from.y + (next.y - from.y) * ease)
  }

  private static func positive(_ value: Double, modulo period: Double) -> Double {
    let remainder = value.truncatingRemainder(dividingBy: period)
    return remainder < 0 ? remainder + period : remainder
  }

  private static func wrap(_ step: Double, _ count: Int) -> Int64 {
    Int64(positive(step, modulo: Double(count)))
  }

  private static func target(_ hash: UInt64, _ step: Int64) -> (x: Double, y: Double) {
    let value = mix(hash, step)
    if value % 3 == 0 { return (0, 0) }
    return (
      (Double(value % 1000) / 500 - 1) * 0.035, (Double((value >> 20) % 1000) / 500 - 1) * 0.022
    )
  }

  private static func mix(_ hash: UInt64, _ step: Int64) -> UInt64 {
    var value = (hash ^ UInt64(bitPattern: step)) &* 0x9E37_79B9_7F4A_7C15
    value ^= value >> 31
    return value &* 0xBF58_476D_1CE4_E5B9 >> 7
  }
}

public struct BotAvatarView: View {
  let seed: String
  let size: CGFloat
  var state: BotState = .idle
  /// Live avatars breathe, glance, blink and watch the pointer; they hop while working and doze
  /// while asleep. Core Animation plays the motion, so they cost the app nothing between changes.
  var live = false
  var reaction = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.botFinish) private var finish
  @State private var pointer: CGPoint?

  public init(seed: String, size: CGFloat, state: BotState = .idle, live: Bool = false, reaction: Int = 0) {
    self.seed = seed
    self.size = size
    self.state = state
    self.live = live
    self.reaction = reaction
  }

  public var body: some View {
    let look = BotLook(seed: seed, finish: finish)
    Group {
      if !live || reduceMotion {
        BotCanvas(look: look, size: size, pose: .rest, expression: state.expression)
      } else {
        BotLayerAvatar(look: look, size: size, state: state, pointer: pointer, reaction: reaction)
          .contentShape(.rect)
          .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointer = point
            case .ended: pointer = nil
            }
          }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Where the pointer hovers, as a fraction of the size, and when it arrived or left, so the face
/// eases into and out of watching it.
struct BotAttention: Equatable {
  var point = CGPoint(x: 0.5, y: 0.5)
  var active = false
  var since = Date.distantPast

  mutating func look(at location: CGPoint, size: CGFloat) {
    if !active { since = .now }
    active = true
    point = CGPoint(x: location.x / size, y: location.y / size)
  }

  mutating func release() {
    active = false
    since = .now
  }

  func amount(at time: Double) -> Double {
    let progress = min(1, max(0, (time - since.timeIntervalSinceReferenceDate) / 0.22))
    let eased = progress * progress * (3 - 2 * progress)
    return active ? eased : 1 - eased
  }
}

/// One frame of a live avatar at a moment in time, for scrubbing and snapshots.
public struct BotAvatarStill: View {
  let look: BotLook
  let size: CGFloat
  let state: BotState
  let time: Double
  let attention: BotAttention
  @Environment(\.botFinish) private var finish

  public init(seed: String, size: CGFloat, state: BotState, time: Double, pointer: CGPoint? = nil) {
    var attention = BotAttention()
    if let pointer { attention.look(at: pointer, size: size) }
    attention.since = .distantPast
    self.init(look: BotLook(seed: seed), size: size, state: state, time: time, attention: attention)
  }

  init(look: BotLook, size: CGFloat, state: BotState, time: Double, attention: BotAttention) {
    self.look = look
    self.size = size
    self.state = state
    self.time = time
    self.attention = attention
  }

  public var body: some View {
    BotLiveFrame(
      look: BotLook(look, finish: finish), size: size, time: time, blend: BotBlend(state: state),
      attention: attention, reactionTime: Date.distantPast.timeIntervalSinceReferenceDate)
  }
}

extension BotPose {
  /// Turns the eyes toward a point and perks up, by `pull` from none to all the way.
  func watching(_ point: CGPoint, pull: Double) -> BotPose {
    guard pull > 0 else { return self }
    var pose = self
    let targetX = min(0.045, max(-0.045, (point.x - 0.6) * 0.1))
    let targetY = min(0.03, max(-0.03, (point.y - 0.46) * 0.08))
    pose.gazeX += (targetX - gazeX) * pull
    pose.gazeY += (targetY - gazeY) * pull
    pose.lift += 0.008 * pull
    pose.scaleY += 0.01 * pull
    return pose
  }
}

extension BotState {
  var expression: BotExpression {
    switch self {
    case .idle: .calm
    case .working: .focused
    case .sleeping: .asleep
    }
  }
}

/// Two Zs that rise from a sleeping bot, grow, and fade, one after the other.
struct SleepZs: View {
  let size: CGFloat
  let time: Double

  var body: some View {
    ZStack {
      ForEach(0..<2, id: \.self) { index in
        let phase = (time / 3 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
        Text("z")
          .font(.system(size: size * 0.26, weight: .heavy, design: .rounded))
          .foregroundStyle(.secondary)
          .scaleEffect((0.16 + 0.1 * phase) / 0.26)
          .opacity(sin(phase * .pi))
          .offset(x: size * (0.34 + 0.12 * phase), y: -size * (0.22 + 0.32 * phase))
      }
    }
    .allowsHitTesting(false)
  }
}
