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

    public init(seed: String) {
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

    /// Breathes, rocks a little, glances around and blinks, sometimes twice.
    static func idle(at time: Double, hash: UInt64) -> BotPose {
        let local = time + Double(hash % 10_000) / 1000
        let breath = sin(local * 2 * .pi / 3.6)
        let roll = sin(local * 0.5) * 2.2
        let gaze = glance(at: local, hash: hash)
        return BotPose(
            gazeX: gaze.x, gazeY: gaze.y, roll: roll, lid: blink(at: local, hash: hash), lift: 0.006 * (breath + 1),
            scaleX: 1 - 0.012 * breath, scaleY: 1 + 0.022 * breath, sway: -roll * 1.6 + sin(local * 1.3) * 3)
    }

    /// Leans aside and sways as Hermex's working face does, hopping on the spot as it goes:
    /// each landing is one squash on the ground that springs into the next jump, and its topper
    /// swings once per hop.
    static func working(at time: Double) -> BotPose {
        let turn = -11 + sin(time * 0.48) * 8
        let tilt = sin(time * 0.42) * 8 + sin(time * 1.1) * 1.6
        let blink = time.truncatingRemainder(dividingBy: 1.45) > 1.26
        let hop = time.truncatingRemainder(dividingBy: 0.9) / 0.9
        let ground = 0.12
        let contact = min(hop, 1 - hop)
        let squash = contact < ground ? 1 - 0.1 * cos(contact / ground * .pi / 2) : 1
        let air = contact < ground ? 0 : (hop - ground) / (1 - 2 * ground)
        return BotPose(
            gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: sin(time * 0.75) * 4.2, lid: blink ? shutLid : 1,
            lift: 0.07 * sin(air * .pi), scaleX: 2 - squash, scaleY: squash, mouthOpen: 0.5 + 0.5 * sin(time * 4.4),
            sway: -sin(air * 2 * .pi) * 9 - sin(time * 0.75) * 4, glow: 0.55 + 0.45 * sin(time * 5))
    }

    /// Breathes slowly with the head dropped a little and the mouth rising and falling.
    static func sleeping(at time: Double) -> BotPose {
        let breath = sin(time * 2 * .pi / 4)
        return BotPose(
            gazeY: 0.03, roll: -5 + sin(time * 0.4) * 1.5, scaleX: 1 - 0.02 * breath, scaleY: 1 + 0.035 * breath,
            mouthOpen: 0.5 + 0.5 * breath, sway: 6 + breath * 3)
    }

    /// Blinks for 180 ms every 3 to 5 seconds, seeded so faces never blink together; every third
    /// blink is a double.
    static func blink(at time: Double, hash: UInt64) -> Double {
        let period = 3 + Double(hash % 2001) / 1000
        let cycle = floor(time / period)
        let offset = time - cycle * period
        let shut = 0.18
        let closed = { (moment: Double) in 1 - (1 - shutLid) * sin(moment / shut * .pi) }
        if offset < shut { return closed(offset) }
        let double = mix(hash, Int64(cycle)) % 3 == 0
        if double, offset > 0.28, offset < 0.28 + shut { return closed(offset - 0.28) }
        return 1
    }

    /// Holds a gaze for two to three and a half seconds, then darts to the next one.
    static func glance(at time: Double, hash: UInt64) -> (x: Double, y: Double) {
        let hold = 2 + Double((hash >> 8) % 1500) / 1000
        let step = floor(time / hold)
        let into = (time - step * hold) / 0.14
        let ease = into >= 1 ? 1 : into * into * (3 - 2 * into)
        let from = target(hash, Int64(step) - 1)
        let next = target(hash, Int64(step))
        return (from.x + (next.x - from.x) * ease, from.y + (next.y - from.y) * ease)
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
    /// while asleep. Small ones in lists stay still.
    var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var attention = BotAttention()

    public init(seed: String, size: CGFloat, state: BotState = .idle, live: Bool = false) {
        self.seed = seed
        self.size = size
        self.state = state
        self.live = live
    }

    public var body: some View {
        let look = BotLook(seed: seed)
        Group {
            if !live || reduceMotion {
                BotCanvas(look: look, size: size, pose: .rest, expression: state.expression)
            } else {
                TimelineView(.animation(minimumInterval: state == .sleeping ? 1.0 / 15 : 1.0 / 30)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    BotAvatarStill(look: look, size: size, state: state, time: time, attention: attention)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): attention.look(at: point, size: size)
                    case .ended: attention.release()
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
        switch state {
        case .sleeping:
            BotCanvas(look: look, size: size, pose: .sleeping(at: time), expression: .asleep)
                .overlay { SleepZs(size: size, time: time) }
        case .working:
            BotCanvas(look: look, size: size, pose: .working(at: time), expression: .focused)
        case .idle:
            let pull = attention.amount(at: time)
            let pose = BotPose.idle(at: time, hash: look.hash).watching(attention.point, pull: pull)
            BotCanvas(look: look, size: size, pose: pose, expression: pull > 0.5 ? .delighted : .calm)
        }
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
        pose.lift += 0.015 * pull
        pose.scaleY += 0.02 * pull
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
