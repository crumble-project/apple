import SwiftUI

/// Where a message sits in a run from one sender: Messages draws the tail on the last bubble
/// and the sender's name on the first.
struct BubblePlace: Equatable {
  var startsRun = true
  var endsRun = true

  /// The gap above a row, tight inside a run.
  var gap: CGFloat { startsRun ? 10 : 2 }

  /// `sender` is nil for a row that isn't a bubble, which ends the run around it.
  static func places<Row>(_ rows: [Row], sender: (Row) -> String?) -> [BubblePlace] {
    let senders = rows.map(sender)
    return senders.indices.map { index in
      guard let current = senders[index] else { return BubblePlace() }
      return BubblePlace(
        startsRun: index == 0 || senders[index - 1] != current,
        endsRun: index == senders.count - 1 || senders[index + 1] != current)
    }
  }
}

/// A rounded message bubble, with the Messages tail curling out of its bottom corner.
struct BubbleShape: Shape {
  static let radius: CGFloat = 18
  /// How far the tail reaches past the bubble.
  static let tailWidth: CGFloat = 5
  let owner: Bool
  let tail: Bool

  func path(in rect: CGRect) -> Path {
    let path = Path(roundedRect: rect, cornerRadius: Self.radius, style: .continuous)
    guard tail else { return path }
    let right = rect.maxX
    let bottom = rect.maxY
    var curl = Path()
    curl.move(to: CGPoint(x: right, y: bottom - 15))
    curl.addCurve(
      to: CGPoint(x: right + Self.tailWidth, y: bottom),
      control1: CGPoint(x: right, y: bottom - 6),
      control2: CGPoint(x: right + 1.5, y: bottom - 2))
    curl.addCurve(
      to: CGPoint(x: right - 9, y: bottom - 2),
      control1: CGPoint(x: right, y: bottom + 0.5),
      control2: CGPoint(x: right - 5, y: bottom - 0.2))
    curl.closeSubpath()
    if !owner {
      curl = curl.applying(
        CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
    }
    // A union, because mirroring reverses the winding and a plain fill would cut the overlap out.
    return path.union(curl)
  }
}

extension View {
  /// The bubble a message sits in: blue for the owner, gray otherwise.
  func bubble(owner: Bool, tail: Bool = true) -> some View {
    padding(.horizontal, 12)
      .padding(.vertical, 7)
      .foregroundStyle(owner ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(
        owner ? Color(.systemBlue) : Color(.systemGray5),
        in: BubbleShape(owner: owner, tail: tail))
      .padding(owner ? .trailing : .leading, BubbleShape.tailWidth)
  }

  /// A swipe across a message starts a reply, as in Messages. Long-pressing offers the same.
  func swipeToReply(enabled: Bool = true, reply: @escaping () -> Void) -> some View {
    modifier(SwipeToReply(enabled: enabled, reply: reply))
  }
}

extension View {
  /// Leaves the swipe from the screen's edge as the way back, as a chat's bubbles need the swipe
  /// across the screen, which the system otherwise takes first.
  func keepsContentSwipe() -> some View {
    background(EdgeSwipeOnly().frame(width: 0, height: 0))
  }
}

private struct EdgeSwipeOnly: UIViewControllerRepresentable {
  final class Controller: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
    }
  }

  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) {}
}

private struct SwipeToReply: ViewModifier {
  private static let threshold: CGFloat = 56
  let enabled: Bool
  let reply: () -> Void
  @GestureState private var offset: CGFloat = 0

  private var drag: some Gesture {
    DragGesture(minimumDistance: 24)
      .updating($offset) { value, offset, _ in
        let width = value.translation.width
        guard width > 0, width > abs(value.translation.height) * 2 else { return }
        offset = min(width * 0.6, Self.threshold + 16)
      }
      .onEnded { value in
        let width = value.translation.width
        if width * 0.6 >= Self.threshold, width > abs(value.translation.height) * 2 { reply() }
      }
  }

  func body(content: Content) -> some View {
    content
      .offset(x: offset)
      .background(alignment: .leading) {
        Image(systemName: "arrowshape.turn.up.left.fill")
          .foregroundStyle(.secondary)
          .opacity(min(1, offset / Self.threshold))
          .offset(x: offset - 30)
          .accessibilityHidden(true)
      }
      .animation(.spring(duration: 0.25), value: offset)
      .sensoryFeedback(.impact(weight: .light), trigger: offset >= Self.threshold) { _, reached in reached }
      .simultaneousGesture(drag, including: enabled ? .all : .subviews)
  }
}

/// Three dots in a gray bubble while a bot writes.
struct TypingBubble: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private func opacity(_ dot: Int, at date: Date) -> Double {
    guard !reduceMotion else { return 0.6 }
    let phase = date.timeIntervalSinceReferenceDate * 3 - Double(dot) * 0.6
    return 0.45 + 0.5 * max(0, sin(phase))
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
      HStack(spacing: 4) {
        ForEach(0..<3, id: \.self) { dot in
          Circle()
            .fill(.secondary)
            .frame(width: 8, height: 8)
            .opacity(opacity(dot, at: context.date))
        }
      }
      .padding(.vertical, 5)
    }
    .bubble(owner: false)
    .accessibilityHidden(true)
  }
}
