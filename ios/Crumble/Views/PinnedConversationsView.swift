import apfelkern
import BotAvatar
import Observation
import SwiftUI

/// A conversation being dragged by its portrait, like a pin in Messages. A pin trades places with
/// the pins it passes over and is unpinned when dropped outside them; a chat from the list is
/// pinned when dropped on them.
///
/// The system's drag and drop can't do this here: a `List` doesn't deliver drops to views inside
/// its rows or headers, so the drag is a long press followed by a drag gesture.
@MainActor @Observable
final class ConversationDrag {
  private(set) var route: Route?
  private(set) var location: CGPoint = .zero
  private var startedPinned = false
  /// The pin the dragged one last traded places with. Pins report their new places a moment after
  /// a trade, so trading again with the same pin before the finger leaves it would undo the trade.
  private var lastTrade: Route?
  /// Where each pin, the whole pin area, and the list are, in global coordinates: a named space
  /// doesn't reach into a `List`'s rows.
  @ObservationIgnored var pinFrames: [Route: CGRect] = [:]
  @ObservationIgnored var pinArea: CGRect = .zero
  var listFrame: CGRect = .zero

  /// The pin area, a little taller, so a pin dropped at its edge stays pinned.
  private var pinDropArea: CGRect { pinArea.insetBy(dx: 0, dy: -12) }

  /// Whether a dragged chat from the list is over the pins and would be pinned there.
  var isOverPins: Bool { route != nil && !startedPinned && pinDropArea.contains(location) }

  private func pin(at point: CGPoint) -> Route? {
    pinFrames.first { $0.value.contains(point) }?.key
  }

  func move(_ dragged: Route, to point: CGPoint, model: AppModel) {
    if route != dragged {
      route = dragged
      startedPinned = model.isPinned(dragged)
      lastTrade = nil
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    location = point
    guard startedPinned else { return }
    guard let target = pin(at: point), target != dragged else {
      if pin(at: point) == nil { lastTrade = nil }
      return
    }
    guard target != lastTrade else { return }
    lastTrade = target
    withAnimation(.snappy) { model.dropOnPin(dragged, target: target) }
  }

  func end(_ dragged: Route, model: AppModel) {
    guard route == dragged else { return }
    let inPins = pinDropArea.contains(location)
    let target = pin(at: location)
    withAnimation(.snappy) {
      if startedPinned, !inPins {
        model.setPinned(dragged, false)
      } else if !startedPinned, inPins {
        if let target { model.dropOnPin(dragged, target: target) } else { model.setPinned(dragged, true) }
      }
      route = nil
    }
  }

  func cancel(_ dragged: Route) {
    guard route == dragged else { return }
    withAnimation(.snappy) { route = nil }
  }
}

/// A conversation's portrait as a pin shows it: the bot, or two members of a group, on a circle.
struct ConversationPortrait: View {
  @Environment(AppModel.self) private var model
  let conversation: Conversation
  let size: CGFloat

  var body: some View {
    Group {
      switch conversation {
      case .bot(let agent):
        BotAvatarView(agent: agent, size: size * 0.66, state: model.botState(agent))
      case .group(let group):
        let members = group.memberIds.compactMap { id in model.agents.first { $0.id == id } }
        ZStack(alignment: .topLeading) {
          ForEach(Array(members.prefix(2).enumerated()), id: \.element.id) { index, agent in
            BotAvatarView(agent: agent, size: size * 0.44, state: .idle)
              .offset(x: CGFloat(index) * size * 0.22, y: CGFloat(index) * size * 0.22)
          }
        }
        .frame(width: size * 0.66, height: size * 0.66, alignment: .topLeading)
      }
    }
    .frame(width: size, height: size)
    .background(Color(.systemGray6), in: .circle)
  }
}

/// Pinned conversations above the list, like Messages: large portraits, three to a row, centered.
struct PinnedConversationsView: View {
  @Environment(AppModel.self) private var model
  @Environment(ConversationDrag.self) private var drag
  let conversations: [Conversation]

  var body: some View {
    // One ForEach in one layout, so a pin keeps its identity, and its drag, as it changes rows.
    PinGrid(columns: 3, spacing: 14, rowSpacing: 22) {
      ForEach(conversations) { PinnedConversationButton(conversation: $0) }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 26)
    .padding(.bottom, 12)
    .background {
      RoundedRectangle(cornerRadius: 24)
        .fill(Color.accentColor.opacity(drag.isOverPins ? 0.08 : 0))
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
      drag.pinArea = $0
    }
  }
}

/// Rows of up to `columns` views, each row centered, like Messages' pins.
private struct PinGrid: Layout {
  let columns: Int
  let spacing: CGFloat
  let rowSpacing: CGFloat

  private func rows(_ subviews: Subviews) -> [[LayoutSubview]] {
    stride(from: 0, to: subviews.count, by: columns).map {
      Array(subviews[$0..<min($0 + columns, subviews.count)])
    }
  }

  private func rowSize(_ row: [LayoutSubview]) -> CGSize {
    let sizes = row.map { $0.sizeThatFits(.unspecified) }
    let width = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
    return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = rows(subviews).map(rowSize)
    let height = sizes.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(sizes.count - 1, 0))
    return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var top = bounds.minY
    for row in rows(subviews) {
      let size = rowSize(row)
      var leading = bounds.midX - size.width / 2
      for subview in row {
        let fitted = subview.sizeThatFits(.unspecified)
        subview.place(at: CGPoint(x: leading, y: top), proposal: ProposedViewSize(fitted))
        leading += fitted.width + spacing
      }
      top += size.height + rowSpacing
    }
  }
}

private struct PinnedConversationButton: View {
  @Environment(AppModel.self) private var model
  @Environment(ConversationDrag.self) private var drag
  let conversation: Conversation
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 92
  @State private var showingMenu = false

  private var route: Route { conversation.route }
  private var unread: Bool { model.unread.count(route) > 0 }
  private var selected: Bool {
    model.route == route && UIDevice.current.userInterfaceIdiom != .phone
  }

  private var name: String {
    switch conversation {
    case .bot(let agent): agent.name
    case .group(let group): group.name
    }
  }

  /// Messages shows what an unread pin last said in a bubble over its portrait.
  private var bubble: String? {
    guard unread else { return nil }
    let text: String? =
      switch conversation {
      case .bot(let agent): model.conversationSummaries[route]?.preview ?? agent.lastMessage
      case .group: model.conversationSummaries[route]?.preview
      }
    return text.map(preview)?.nilIfEmpty
  }

  var body: some View {
    VStack(spacing: 6) {
      ConversationPortrait(conversation: conversation, size: size)
        .overlay {
          if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 3) }
        }
        .overlay(alignment: .topLeading) {
          if unread, bubble == nil { unreadDot }
        }
        .overlay(alignment: .top) {
          if let bubble { PinBubble(text: bubble, width: size + 10).offset(y: -22) }
        }
      Text(name)
        .font(.footnote.weight(unread ? .semibold : .regular))
        .foregroundStyle(unread ? .primary : .secondary)
        .lineLimit(1)
        .frame(maxWidth: size + 8)
    }
    .contentShape(.rect)
    // A tap gesture, not a Button, which would take the touch from the drag.
    .onTapGesture { model.navigate(to: route) }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.navigate(to: route) }
    .opacity(drag.route == route ? 0.25 : 1)
    .disabled(model.pendingMutations.contains(mutationKey))
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
      drag.pinFrames[route] = $0
    }
    .onDisappear {
      drag.pinFrames[route] = nil
      drag.cancel(route)
    }
    .draggableConversation(route, drag: drag, model: model)
    // A list header shows no context menu, so holding a pin still opens this one instead.
    // Moving before it opens drags the pin.
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.6).onEnded { _ in
        if drag.route == nil { showingMenu = true }
      }
    )
    .onChange(of: drag.route) { _, dragged in
      if dragged == route { showingMenu = false }
    }
    .confirmationDialog(name, isPresented: $showingMenu, titleVisibility: .visible) {
      Button("Open") { model.navigate(to: route) }
      Button("Unpin", role: .destructive) { withAnimation { model.setPinned(route, false) } }
    }
    .accessibilityLabel(name)
    .accessibilityValue(unread ? "Pinned, Unread" : "Pinned")
    .accessibilityAction(named: "Unpin") { model.setPinned(route, false) }
  }

  private var unreadDot: some View {
    Circle()
      .fill(Color(.systemBlue))
      .frame(width: 14, height: 14)
      .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
  }

  private var mutationKey: String {
    switch conversation {
    case .bot(let agent): "agent:\(agent.id)"
    case .group(let group): "group:\(group.id)"
    }
  }
}

/// The latest unread message in a small bubble over a pin.
private struct PinBubble: View {
  let text: String
  let width: CGFloat

  var body: some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(.primary)
      .lineLimit(2)
      .multilineTextAlignment(.leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .background(Color(.systemBackground), in: .rect(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator), lineWidth: 0.5) }
      .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
      .accessibilityHidden(true)
  }
}

/// The dragged conversation's portrait under the finger.
struct ConversationDragPreview: View {
  @Environment(AppModel.self) private var model
  @Environment(ConversationDrag.self) private var drag

  var body: some View {
    let dragged = drag.route.flatMap { route in
      (model.pinnedConversations + model.conversations).first { $0.route == route }
    }
    if let dragged {
      ConversationPortrait(conversation: dragged, size: 80)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        .scaleEffect(1.05)
        .position(x: drag.location.x - drag.listFrame.minX, y: drag.location.y - drag.listFrame.minY)
        .allowsHitTesting(false)
        .transition(.scale.combined(with: .opacity))
    }
  }
}

private struct DraggableConversation: ViewModifier {
  let route: Route
  let drag: ConversationDrag
  let model: AppModel
  @GestureState private var pressing = false

  private var gesture: some Gesture {
    LongPressGesture(minimumDuration: 0.25)
      .sequenced(before: DragGesture(minimumDistance: 10, coordinateSpace: .global))
      .updating($pressing) { value, state, _ in
            if case .second(true, _) = value { state = true }
          }
      .onChanged { value in
            guard case .second(true, let movement?) = value else { return }
            drag.move(route, to: movement.location, model: model)
          }
      .onEnded { _ in drag.end(route, model: model) }
  }

  func body(content: Content) -> some View {
    // Alongside, not instead of, the row's Button and the pin's tap, which an exclusive gesture
    // would take. The long press first keeps a scroll from starting a drag.
    content
      .simultaneousGesture(gesture)
      .onChange(of: pressing) { _, now in
        if !now { drag.cancel(route) }
      }
  }
}

extension View {
  /// Touch and hold, then drag: pins reorder and unpin, and chats from the list pin.
  func draggableConversation(_ route: Route, drag: ConversationDrag, model: AppModel) -> some View {
    modifier(DraggableConversation(route: route, drag: drag, model: model))
  }

  /// Messages' pin: a leading swipe and a context menu item. The row's portrait drags it onto the
  /// pins (`ConversationRow`): a drag gesture on the whole row would block the swipe.
  /// `menu` adds the row's own items.
  func pinnable<Menu: View>(
    _ route: Route, model: AppModel, drag: ConversationDrag,
    @ViewBuilder menu: () -> Menu = { EmptyView() }
  ) -> some View {
    let canPin = model.canPin(route)
    return
      self
      .opacity(drag.route == route ? 0.4 : 1)
      .contextMenu {
        Button("Pin", systemImage: "pin") { withAnimation { model.setPinned(route, true) } }
          .disabled(!canPin)
        menu()
      }
      .swipeActions(edge: .leading) {
        if canPin {
          Button("Pin", systemImage: "pin.fill") { withAnimation { model.setPinned(route, true) } }
            .tint(.yellow)
        }
      }
  }
}
