import QuartzCore
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The layer tree of a live avatar. Lengths are in points; the tree uses a bottom-left origin on
/// every platform, so points from the drawing's top-left origin are flipped as they come in.
@MainActor
final class BotRig {
  let root = CALayer()
  private let size: CGFloat
  private let geometry: BotGeometry
  private let shadow: CALayer
  private let lift = CALayer()
  private let squash = CALayer()
  private let roll = CALayer()
  private let topper = CALayer()
  private let glow: CALayer
  private let look = CALayer()
  private let eyes = CALayer()
  private let leftEye: CALayer
  private let rightEye: CALayer
  private let closedEyes: CALayer
  private let mouthLook = CALayer()
  private let mouth = CALayer()
  private var mouths: [BotExpression: CALayer] = [:]
  private let sleepZs = CALayer()
  private let zLetters = [CATextLayer(), CATextLayer()]
  private var state = BotState.idle
  private var watching = false

  init(look bot: BotLook, size: CGFloat) {
    self.size = size
    geometry = BotGeometry(look: bot, size: size)
    let sprite = { (part: BotPart) in BotSprites.layer(bot, size: size, part: part) }
    shadow = sprite(.shadow)
    glow = sprite(.glow)
    glow.opacity = 0
    leftEye = sprite(.eye(left: true))
    rightEye = sprite(.eye(left: false))
    closedEyes = sprite(.closedEyes)
    root.frame = CGRect(x: 0, y: 0, width: size, height: size)
    #if !os(macOS)
      // UIKit layers start at the top left; flipping the root gives the tree AppKit's origin.
      root.isGeometryFlipped = true
    #endif
    pin(shadow, at: geometry.shadow)
    for layer in [lift, look, eyes, mouthLook, mouth, sleepZs] { pin(layer, at: CGPoint(x: size / 2, y: size / 2)) }
    for layer in [squash, roll] { pin(layer, at: geometry.base) }
    pin(topper, at: geometry.topper)
    pin(leftEye, at: geometry.leftEye)
    pin(rightEye, at: geometry.rightEye)
    root.addSublayer(shadow)
    root.addSublayer(lift)
    lift.addSublayer(squash)
    squash.addSublayer(roll)
    topper.addSublayer(sprite(.topper))
    topper.addSublayer(glow)
    roll.addSublayer(topper)
    roll.addSublayer(sprite(.body))
    roll.addSublayer(look)
    look.addSublayer(eyes)
    for layer in [leftEye, rightEye, closedEyes] { eyes.addSublayer(layer) }
    roll.addSublayer(mouthLook)
    mouthLook.addSublayer(mouth)
    for expression in [BotExpression.calm, .delighted, .focused, .asleep] {
      let layer = sprite(.mouth(expression))
      pin(layer, at: geometry.mouth)
      mouth.addSublayer(layer)
      mouths[expression] = layer
    }
    root.addSublayer(sleepZs)
    setUpZs(seed: bot.hash)
  }

  /// Places a full-square layer so it scales and turns around `point`, given from the top left.
  private func pin(_ layer: CALayer, at point: CGPoint) {
    layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
    layer.anchorPoint = CGPoint(x: point.x / size, y: 1 - point.y / size)
    layer.position = CGPoint(x: point.x, y: size - point.y)
  }

  // MARK: Loops

  /// Replaces the running loops with the state's, sampled from its pose 30 times a second.
  func play(_ state: BotState, look bot: BotLook, from start: CFTimeInterval) {
    self.state = state
    let loop = BotLoop(state: state, look: bot)
    let count = Int(loop.length * 30)
    let poses = (0...count).map { loop.pose(at: Double($0) / Double(count) * loop.length / loop.speed) }
    let times = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
    let duration = loop.length / loop.speed
    let animate = { (layer: CALayer, path: String, value: (BotPose) -> Double) in
      let animation = CAKeyframeAnimation(keyPath: path)
      animation.values = poses.map { NSNumber(value: value($0)) }
      animation.keyTimes = times
      animation.duration = duration
      animation.beginTime = start
      animation.repeatCount = .infinity
      // iOS removes running animations from backgrounded apps unless they opt out.
      animation.isRemovedOnCompletion = false
      layer.add(animation, forKey: "loop." + path)
    }
    let size = size
    let shut = geometry.shutScale
    animate(lift, "transform.translation.y") { $0.lift * size }
    animate(squash, "transform.scale.x") { $0.scaleX }
    animate(squash, "transform.scale.y") { $0.scaleY }
    animate(roll, "transform.rotation.z") { -$0.roll * .pi / 180 }
    animate(topper, "transform.rotation.z") { -$0.sway * .pi / 180 }
    animate(glow, "opacity") { $0.glow }
    animate(eyes, "transform.translation.x") { $0.gazeX * size }
    animate(eyes, "transform.translation.y") { -$0.gazeY * size }
    animate(mouth, "transform.translation.x") { $0.gazeX * size * 0.65 }
    animate(mouth, "transform.translation.y") { -$0.gazeY * size * 0.65 }
    for eye in [leftEye, rightEye] { animate(eye, "transform.scale.y") { max(shut, $0.lid) } }
    if let focused = mouths[.focused] {
      animate(focused, "transform.scale.y") { (0.03 + 0.022 * $0.mouthOpen) / 0.052 }
    }
    if let asleep = mouths[.asleep] {
      animate(asleep, "transform.scale.y") { (0.022 + 0.016 * $0.mouthOpen) / 0.038 }
    }
    let rise = { (pose: BotPose) in min(1, pose.lift * 9) }
    animate(shadow, "transform.scale.x") { $0.scaleX * (1 - 0.35 * rise($0)) }
    animate(shadow, "transform.scale.y") { 1 - 0.3 * rise($0) }
    animate(shadow, "opacity") { 1 - 0.55 * rise($0) }
  }

  /// Eases from where the last loop left the body into the new loop, so state changes glide.
  func bridge(from old: BotPose, to new: BotPose, duration: Double) {
    let ease = { (layer: CALayer, path: String, delta: Double) in
      guard abs(delta) > 0.0001 else { return }
      let animation = CABasicAnimation(keyPath: path)
      animation.fromValue = delta
      animation.toValue = 0
      animation.isAdditive = true
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(animation, forKey: "bridge." + path)
    }
    ease(lift, "transform.translation.y", (old.lift - new.lift) * size)
    ease(roll, "transform.rotation.z", -(old.roll - new.roll) * .pi / 180)
    ease(topper, "transform.rotation.z", -(old.sway - new.sway) * .pi / 180)
    ease(eyes, "transform.translation.x", (old.gazeX - new.gazeX) * size)
    ease(eyes, "transform.translation.y", -(old.gazeY - new.gazeY) * size)
    ease(mouth, "transform.translation.x", (old.gazeX - new.gazeX) * size * 0.65)
    ease(mouth, "transform.translation.y", -(old.gazeY - new.gazeY) * size * 0.65)
  }

  // MARK: Expression

  /// Shows the eyes, mouth and Zs that suit the state, fading between them when `animated`.
  func express(_ state: BotState, animated: Bool) {
    self.state = state
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(state == .sleeping ? 0.6 : 0.3)
    let asleep: Float = state == .sleeping ? 1 : 0
    leftEye.opacity = 1 - asleep
    rightEye.opacity = 1 - asleep
    closedEyes.opacity = asleep
    sleepZs.opacity = asleep
    let calm = state == .idle && !watching
    mouths[.calm]?.opacity = calm ? 1 : 0
    mouths[.delighted]?.opacity = state == .idle && watching ? 1 : 0
    mouths[.focused]?.opacity = state == .working ? 1 : 0
    mouths[.asleep]?.opacity = asleep
    CATransaction.commit()
  }

  /// Turns the eyes toward the pointer, given from the top left, and smiles; `nil` lets go.
  func watch(_ pointer: CGPoint?, size: CGFloat, state: BotState) {
    guard (pointer != nil) != watching || pointer != nil else { return }
    let gaze = pointer.map { point in
      CGPoint(
        x: min(0.045, max(-0.045, (point.x / size - 0.6) * 0.1)),
        y: min(0.03, max(-0.03, (point.y / size - 0.46) * 0.08)))
    } ?? .zero
    let changed = (pointer != nil) != watching
    watching = pointer != nil
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.22)
    look.setAffineTransform(CGAffineTransform(translationX: gaze.x * size, y: -gaze.y * size))
    mouthLook.setAffineTransform(
      CGAffineTransform(translationX: gaze.x * size * 0.65, y: -gaze.y * size * 0.65))
    CATransaction.commit()
    if changed { express(state, animated: true) }
  }

  /// A quick happy hop and wiggle, layered over whatever the bot is doing.
  func greet() {
    let count = 27
    let envelope = (0...count).map { index -> (progress: Double, value: Double) in
      let progress = Double(index) / Double(count)
      return (progress, pow(sin(progress * .pi), 2))
    }
    let times = envelope.map { NSNumber(value: $0.progress) }
    let wiggle = { (layer: CALayer, path: String, value: (Double, Double) -> Double) in
      let animation = CAKeyframeAnimation(keyPath: path)
      animation.values = envelope.map { NSNumber(value: value($0.progress, $0.value)) }
      animation.keyTimes = times
      animation.duration = 0.9
      animation.isAdditive = true
      layer.add(animation, forKey: "greet." + path)
    }
    let size = size
    wiggle(lift, "transform.translation.y") { _, envelope in 0.035 * envelope * size }
    wiggle(roll, "transform.rotation.z") { progress, envelope in
      -sin(progress * .pi * 2) * 4 * envelope * .pi / 180
    }
    wiggle(topper, "transform.rotation.z") { progress, envelope in
      sin(progress * .pi * 2 - 0.5) * 7 * envelope * .pi / 180
    }
    wiggle(glow, "opacity") { _, envelope in envelope }
    if state == .idle, !watching, let calm = mouths[.calm], let delighted = mouths[.delighted] {
      wiggle(calm, "opacity") { _, envelope in -envelope }
      wiggle(delighted, "opacity") { _, envelope in envelope }
    }
  }

  // MARK: Zs

  private func setUpZs(seed: UInt64) {
    let font = BotPlatformFont.systemFont(ofSize: size * 0.26, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).map { BotPlatformFont(descriptor: $0, size: size * 0.26) }
    let offset = Double(seed % 1000) / 1000
    for (index, letter) in zLetters.enumerated() {
      letter.string = "z"
      letter.font = rounded ?? font
      letter.fontSize = size * 0.26
      letter.alignmentMode = .center
      letter.contentsScale = BotSprites.scale
      letter.bounds = CGRect(x: 0, y: 0, width: size * 0.3, height: size * 0.34)
      letter.opacity = 0
      sleepZs.addSublayer(letter)
      let count = 45
      let phases = (0...count).map { step in
        (Double(step) / Double(count) + offset + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
      }
      let times = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
      let animation = CAAnimationGroup()
      let across = CAKeyframeAnimation(keyPath: "position.x")
      across.values = phases.map { NSNumber(value: size * (0.84 + 0.12 * $0)) }
      let rise = CAKeyframeAnimation(keyPath: "position.y")
      rise.values = phases.map { NSNumber(value: size * (0.72 + 0.32 * $0)) }
      let scale = CAKeyframeAnimation(keyPath: "transform.scale")
      scale.values = phases.map { NSNumber(value: (0.16 + 0.1 * $0) / 0.26) }
      let opacity = CAKeyframeAnimation(keyPath: "opacity")
      opacity.values = phases.map { NSNumber(value: sin($0 * .pi)) }
      for track in [across, rise, scale, opacity] {
        track.keyTimes = times
        track.duration = 3
      }
      animation.animations = [across, rise, scale, opacity]
      animation.duration = 3
      animation.repeatCount = .infinity
      animation.isRemovedOnCompletion = false
      letter.add(animation, forKey: "drift")
    }
  }

  func tintZs(_ color: CGColor) {
    for letter in zLetters { letter.foregroundColor = color }
  }
}

/// Drawn parts, kept so avatars that come and go, like rows in a list, draw each part only once.
@MainActor
enum BotSprites {
  private static let cache = NSCache<NSString, CGImage>()

  static func layer(_ look: BotLook, size: CGFloat, part: BotPart) -> CALayer {
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: size, height: size)
    layer.contents = image(look, size: size, part: part)
    layer.contentsScale = scale
    return layer
  }

  static var scale: CGFloat {
    #if os(macOS)
      NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    #else
      3
    #endif
  }

  private static func image(_ look: BotLook, size: CGFloat, part: BotPart) -> CGImage? {
    let key = "\(look.hash)-\(look.finish)-\(size)-\(scale)-\(part)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let renderer = ImageRenderer(content: BotPartCanvas(look: look, size: size, part: part))
    renderer.scale = scale
    guard let image = renderer.cgImage else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }
}
