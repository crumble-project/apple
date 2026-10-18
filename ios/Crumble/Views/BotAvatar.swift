import SwiftUI

// Bot avatars are Hermex's drawn faces (MIT, see THIRD_PARTY_NOTICES.md): a flat shape in one
// color with two leaning capsule eyes. The seed picks the shape and color.

enum BotState { case idle, working, sleeping }

func agentAvatarSeed(_ agent: Agent) -> String {
  let avatar = agent.avatar ?? ""
  for prefix in ["bot:", "critters:"] where avatar.hasPrefix(prefix) {
    let seed = avatar.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    if !seed.isEmpty { return seed }
  }
  return agent.id.trimmingCharacters(in: .whitespaces).isEmpty ? "crumble" : agent.id
}

enum BotShape: CaseIterable { case circle, squircle, pill, triangle, hexagon, cloud, drop }

struct BotLook: Equatable {
  static let palette = [
    "#8b5cf6", "#38bdf8", "#14b8a6", "#22c55e", "#f59e0b", "#f97316", "#ef4444", "#ec4899"
  ]

  let shape: BotShape
  let hex: String
  let hash: UInt64

  init(seed: String) {
    hash = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    shape = BotShape.allCases[Int(hash % UInt64(BotShape.allCases.count))]
    hex = Self.palette[Int(hash % UInt64(Self.palette.count))]
  }

  struct RGB {
    let red: Double
    let green: Double
    let blue: Double
  }

  var rgb: RGB {
    let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
    return RGB(
      red: Double((value >> 16) & 0xff), green: Double((value >> 8) & 0xff), blue: Double(value & 0xff))
  }

  var color: Color {
    let components = rgb
    return Color(red: components.red / 255, green: components.green / 255, blue: components.blue / 255)
  }

  var eyeColor: Color {
    let components = rgb
    let luminance = 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
    return luminance < 110 ? .white.opacity(0.9) : .black.opacity(0.85)
  }
}

/// An expression's eyes in Bloub's units: width and height against the body radius, lean in degrees.
struct BotEyes {
  struct Eye {
    let width: Double
    let height: Double
    let tilt: Double
  }
  let left: Eye
  let right: Eye
  let split: Double

  static let neutral = BotEyes(
    left: Eye(width: 0.186, height: 0.412, tilt: 0),
    right: Eye(width: 0.186, height: 0.412, tilt: 0), split: 15.46)
  static let sleepy = BotEyes(
    left: Eye(width: 0.2, height: 0.42 * 0.42, tilt: 0),
    right: Eye(width: 0.2, height: 0.42 * 0.42, tilt: 0), split: 16)
}

/// One frame of a face: gaze as a fraction of the size, roll in degrees, the lid factor, a lift
/// as a fraction of the size, and the squash and stretch of the body, anchored at its base.
struct BotPose: Equatable {
  var gazeX = 0.0
  var gazeY = 0.0
  var roll = 0.0
  var lid = 1.0
  var lift = 0.0
  var scaleX = 1.0
  var scaleY = 1.0

  static let rest = BotPose()
  static let shutLid = 0.06

  /// Leans aside and sways as Hermex's working face does, hopping on the spot as it goes:
  /// it squashes before each jump and again as it lands.
  static func working(at time: Double) -> BotPose {
    let turn = -11 + sin(time * 0.48) * 8
    let tilt = sin(time * 0.42) * 8 + sin(time * 1.1) * 1.6
    let blink = time.truncatingRemainder(dividingBy: 1.45) > 1.26
    let hop = time.truncatingRemainder(dividingBy: 0.9) / 0.9
    let squash =
      hop < 0.12
      ? 1 - 0.1 * sin(hop / 0.12 * .pi) : hop > 0.88 ? 1 - 0.1 * sin((hop - 0.88) / 0.12 * .pi) : 1
    return BotPose(
      gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: sin(time * 0.75) * 4.2,
      lid: blink ? shutLid : 1,
      lift: 0.07 * sin(hop * .pi), scaleX: 2 - squash, scaleY: squash)
  }

  /// Breathes slowly with the head dropped a little and the eyes cast down.
  static func sleeping(at time: Double) -> BotPose {
    let breath = sin(time * 2 * .pi / 4)
    return BotPose(
      gazeY: 0.03, roll: -5 + sin(time * 0.4) * 1.5, scaleX: 1 - 0.02 * breath,
      scaleY: 1 + 0.035 * breath)
  }
}

/// Blinks for 180 ms every 3 to 5 seconds, seeded so faces in a list never blink together.
/// The timeline fires only at blink edges, so nothing repaints in between.
struct BotBlinkSchedule: TimelineSchedule {
  static let shut = 0.18
  let period: Double
  let phase: Double

  init(hash: UInt64) {
    period = 3 + Double(hash % 2001) / 1000
    phase = Double((hash >> 20) % 5000) / 1000
  }

  func isShut(at date: Date) -> Bool {
    let offset = (date.timeIntervalSinceReferenceDate - phase).truncatingRemainder(
      dividingBy: period)
    return (offset < 0 ? offset + period : offset) + 0.0001 < Self.shut
  }

  func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    let period = period
    let shut = Self.shut
    let base = start.timeIntervalSinceReferenceDate
    let firstShut = phase + (floor((base - phase) / period) + 1) * period
    var edges = [start]
    if isShut(at: start) {
      edges.append(Date(timeIntervalSinceReferenceDate: firstShut - period + shut))
    }
    var index = -1
    return AnyIterator {
      index += 1
      if index < edges.count { return edges[index] }
      let step = index - edges.count
      let blink = firstShut + Double(step / 2) * period
      return Date(timeIntervalSinceReferenceDate: step.isMultiple(of: 2) ? blink : blink + shut)
    }
  }
}

struct BotAvatarView: View {
  let seed: String
  let size: CGFloat
  var state: BotState = .idle
  /// Live avatars blink, hop and sway while working, and breathe while asleep; small ones in lists stay still.
  var live = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(agent: Agent, size: CGFloat, state: BotState = .idle, live: Bool = false) {
    self.init(seed: agentAvatarSeed(agent), size: size, state: state, live: live)
  }

  init(seed: String, size: CGFloat, state: BotState = .idle, live: Bool = false) {
    self.seed = seed
    self.size = size
    self.state = state
    self.live = live
  }

  var body: some View {
    let look = BotLook(seed: seed)
    let eyes: BotEyes = state == .sleeping ? .sleepy : .neutral
    Group {
      if !live || reduceMotion {
        BotMark(look: look, eyes: eyes, size: size, pose: .rest)
      } else if state == .sleeping {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
          let time = context.date.timeIntervalSinceReferenceDate
          BotMark(look: look, eyes: eyes, size: size, pose: .sleeping(at: time))
            .overlay { SleepZs(size: size, time: time) }
        }
      } else if state == .working {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
          BotMark(
            look: look, eyes: eyes, size: size,
            pose: .working(at: context.date.timeIntervalSinceReferenceDate))
        }
      } else {
        let schedule = BotBlinkSchedule(hash: look.hash)
        TimelineView(schedule) { context in
          BotMark(
            look: look, eyes: eyes, size: size,
            pose: schedule.isShut(at: context.date) ? BotPose(lid: BotPose.shutLid) : .rest)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct BotMark: View {
  let look: BotLook
  let eyes: BotEyes
  let size: CGFloat
  let pose: BotPose

  var body: some View {
    ZStack {
      BotBody(shape: look.shape).fill(look.color)
      HStack(spacing: size * 0.1 * eyes.split / 15.46) {
        eye(eyes.left)
        eye(eyes.right)
      }
      .offset(x: size * (0.12 + pose.gazeX), y: size * (-0.08 + pose.gazeY))
    }
    .rotationEffect(.degrees(pose.roll))
    .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
    .offset(y: -size * pose.lift)
    .frame(width: size, height: size)
  }

  private func eye(_ eye: BotEyes.Eye) -> some View {
    Capsule().fill(look.eyeColor)
      .frame(
        width: size * 0.075 * eye.width / 0.186, height: size * 0.22 * eye.height / 0.412 * pose.lid
      )
      .rotationEffect(.degrees(-18 + eye.tilt))
  }
}

/// Two Zs that rise from a sleeping bot, grow, and fade, one after the other.
private struct SleepZs: View {
  let size: CGFloat
  let time: Double

  var body: some View {
    ZStack {
      ForEach(0..<2, id: \.self) { index in
        let phase = (time / 3 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
        Text("z")
          .font(.system(size: size * (0.16 + 0.1 * phase), weight: .heavy, design: .rounded))
          .foregroundStyle(.secondary)
          .opacity(sin(phase * .pi))
          .offset(x: size * (0.34 + 0.12 * phase), y: -size * (0.22 + 0.32 * phase))
      }
    }
    .allowsHitTesting(false)
  }
}

private struct BotBody: Shape {
  let shape: BotShape

  private func cloudPath(in rect: CGRect) -> Path {
    var path = Path()
    path.addEllipse(
      in: CGRect(
        x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.38,
        width: rect.width * 0.48, height: rect.height * 0.48))
    path.addEllipse(
      in: CGRect(
        x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.12,
        width: rect.width * 0.5, height: rect.height * 0.64))
    path.addEllipse(
      in: CGRect(
        x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.35,
        width: rect.width * 0.38, height: rect.height * 0.45))
    return path
  }

  private func hexagonPath(in rect: CGRect, inset: CGRect) -> Path {
    var path = Path()
    path.addLines([
      CGPoint(x: rect.midX, y: inset.minY),
      CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.3),
      CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.7),
      CGPoint(x: rect.midX, y: inset.maxY),
      CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.7),
      CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.3)
    ])
    path.closeSubpath()
    return path
  }

  func path(in rect: CGRect) -> Path {
    let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
    switch shape {
    case .circle:
      return Path(ellipseIn: inset)
    case .squircle:
      return Path(roundedRect: inset, cornerRadius: rect.width * 0.28, style: .continuous)
    case .pill:
      let pill = CGRect(
        x: inset.minX, y: rect.midY - rect.height * 0.27, width: inset.width,
        height: rect.height * 0.54)
      return Path(roundedRect: pill, cornerRadius: pill.height / 2)
    case .triangle:
      var path = Path()
      path.move(to: CGPoint(x: rect.midX, y: inset.minY))
      path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
      path.closeSubpath()
      return path
    case .hexagon:
      return hexagonPath(in: rect, inset: inset)
    case .cloud:
      return cloudPath(in: rect)
    case .drop:
      var path = Path()
      path.move(to: CGPoint(x: rect.midX, y: inset.minY))
      path.addCurve(
        to: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.62),
        control1: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.2),
        control2: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.42))
      path.addCurve(
        to: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.62),
        control1: CGPoint(x: inset.maxX, y: inset.maxY),
        control2: CGPoint(x: inset.minX, y: inset.maxY))
      path.addCurve(
        to: CGPoint(x: rect.midX, y: inset.minY),
        control1: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.42),
        control2: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.2))
      return path
    }
  }
}
