import QuartzCore
import SwiftUI

#if os(macOS)
  import AppKit
  typealias BotPlatformView = NSView
  typealias BotPlatformFont = NSFont
#else
  import UIKit
  typealias BotPlatformView = UIView
  typealias BotPlatformFont = UIFont
#endif

/// A live avatar played by Core Animation: each part is drawn once into a cached image, and each
/// state's motion runs as looping keyframes in the render server, so a running avatar costs the app
/// no work per frame. Only hovering, greetings and state changes touch the layers.
@MainActor
struct BotLayerAvatar {
  let look: BotLook
  let size: CGFloat
  let state: BotState
  let pointer: CGPoint?
  let reaction: Int

  func make() -> BotLayerView {
    BotLayerView(look: look, size: size, state: state)
  }

  func update(_ view: BotLayerView) {
    view.rebuild(look: look, size: size, state: state)
    view.show(state)
    view.watch(state == .idle ? pointer : nil)
    view.greet(reaction)
  }
}

#if os(macOS)
  extension BotLayerAvatar: NSViewRepresentable {
    func makeNSView(context: Context) -> BotLayerView { make() }
    func updateNSView(_ view: BotLayerView, context: Context) { update(view) }
  }
#else
  extension BotLayerAvatar: UIViewRepresentable {
    func makeUIView(context: Context) -> BotLayerView { make() }
    func updateUIView(_ view: BotLayerView, context: Context) { update(view) }
  }
#endif

final class BotLayerView: BotPlatformView {
  private var look: BotLook
  private var size: CGFloat
  private var state: BotState
  private var loopStart = CACurrentMediaTime()
  private var reaction = 0
  private var rig: BotRig

  init(look: BotLook, size: CGFloat, state: BotState) {
    self.look = look
    self.size = size
    self.state = state
    rig = BotRig(look: look, size: size)
    super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
    #if os(macOS)
      wantsLayer = true
    #else
      isUserInteractionEnabled = false
      backgroundColor = .clear
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BotLayerView, _) in view.tintZs() }
    #endif
    hostLayer.masksToBounds = false
    install()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("BotLayerView is created in code") }

  override var intrinsicContentSize: CGSize { CGSize(width: size, height: size) }

  #if os(macOS)
    // Clicks and hovers belong to the SwiftUI views around the avatar.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      tintZs()
    }

    private var hostLayer: CALayer {
      if layer == nil { wantsLayer = true }
      return layer ?? CALayer()
    }

    private func tintZs() {
      var color = NSColor.secondaryLabelColor.cgColor
      effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.secondaryLabelColor.cgColor }
      rig.tintZs(color)
    }
  #else
    private var hostLayer: CALayer { layer }

    private func tintZs() {
      rig.tintZs(UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor)
    }
  #endif

  func rebuild(look: BotLook, size: CGFloat, state: BotState) {
    guard look != self.look || size != self.size else { return }
    rig.root.removeFromSuperlayer()
    self.look = look
    self.size = size
    self.state = state
    rig = BotRig(look: look, size: size)
    install()
  }

  private func install() {
    hostLayer.addSublayer(rig.root)
    tintZs()
    rig.express(state, animated: false)
    loopStart = CACurrentMediaTime()
    rig.play(state, look: look, from: loopStart)
  }

  func show(_ next: BotState) {
    guard next != state else { return }
    let now = CACurrentMediaTime()
    let before = BotLoop(state: state, look: look).pose(at: now - loopStart)
    state = next
    loopStart = now
    rig.play(next, look: look, from: now)
    let after = BotLoop(state: next, look: look).pose(at: 0)
    rig.bridge(from: before, to: after, duration: next == .sleeping ? 0.9 : 0.5)
    rig.express(next, animated: true)
  }

  func watch(_ pointer: CGPoint?) {
    rig.watch(pointer, size: size, state: state)
  }

  func greet(_ count: Int) {
    guard count != reaction else { return }
    reaction = count
    if state != .sleeping { rig.greet() }
  }
}

/// A state's motion as a function of the time since its loop started.
struct BotLoop {
  let state: BotState
  let look: BotLook

  var length: Double { BotPose.loop(state) }
  /// Working bots hop at slightly different tempos, so a room of them never hops in step.
  var speed: Double { state == .working ? 0.92 + Double(look.hash % 17) / 100 : 1 }

  func pose(at elapsed: Double) -> BotPose {
    let phase = Double(look.hash % 10_000) / 1000
    let time = (elapsed * speed).truncatingRemainder(dividingBy: length)
    switch state {
    case .idle: return .idle(at: time, hash: look.hash)
    case .working: return .working(at: time + phase)
    case .sleeping: return .sleeping(at: time + phase)
    }
  }
}
