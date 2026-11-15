import apfelkern
import SwiftUI

extension EnvironmentValues {
  /// The chat whose transcript a view sits in, for its reply surfaces.
  @Entry var attentionChat: ChatAttentionChat?
}

extension View {
  /// Mounts the chat while its transcript shows, and reports what covers its scroll view's edges.
  /// Apply to the chat's scroll view.
  func chatAttention(_ chat: ChatAttentionChat, ready: Bool) -> some View {
    modifier(ChatAttentionMount(chat: chat, ready: ready))
  }

  /// Acknowledges the message's replies on this exact surface once it's ready and on screen.
  func replySurface(_ message: Message, _ surface: ReplySurface, ready: Bool) -> some View {
    modifier(ReplySurfaceReport(
      key: "\(message.id) \(surface)", eventIDs: message.attentionEventIDs(for: surface), ready: ready))
  }

  /// Acknowledges a waiting card once its board has the server's state for it and it's on screen.
  func replyCard(_ message: Message) -> some View {
    modifier(ReplyCardReport(message: message))
  }
}

private struct ChatAttentionMount: ViewModifier {
  @Environment(AppModel.self) private var model
  let chat: ChatAttentionChat
  let ready: Bool

  func body(content: Content) -> some View {
    content
      .environment(\.attentionChat, chat)
      .onScrollGeometryChange(for: EdgeInsets.self) { $0.contentInsets } action: { _, insets in
        model.chatAttention.setViewportInsets(top: insets.top, bottom: insets.bottom)
      }
      // A view can stay while the owner picks another chat, so the chat itself can change.
      .onChange(of: ready ? chat : nil, initial: true) { old, new in
        if let old, old != new { model.chatAttention.unmount(old) }
        if let new { model.chatAttention.mount(new) }
      }
      .onAppear { if ready { model.chatAttention.mount(chat) } }
      .onDisappear { model.chatAttention.unmount(chat) }
  }
}

private struct ReplyCardReport: ViewModifier {
  @Environment(AppModel.self) private var model
  let message: Message

  func body(content: Content) -> some View {
    let card = message.replyCard(
      heldActions: model.heldActionBoard, botRequests: model.botRequestBoard,
      callRequests: model.callRequestBoard, botSecrets: model.botSecretBoard)
    content.modifier(ReplySurfaceReport(
      key: "\(message.id) card", eventIDs: card.map { message.attentionEventIDs(for: $0.surface) } ?? [],
      ready: card?.ready ?? false))
  }
}

/// Reports a surface's frame in its scroll view while it has replies to acknowledge. The policy of what counts
/// as seen lives in `ChatAttention`.
private struct ReplySurfaceReport: ViewModifier {
  struct Placement: Equatable {
    var frame: CGRect
    var container: CGSize
  }

  private struct Report: Equatable {
    var chat: ChatAttentionChat?
    var placement: Placement?
    var eventIDs: [String]
    var ready: Bool
  }

  @Environment(AppModel.self) private var model
  @Environment(\.attentionChat) private var chat
  let key: String
  let eventIDs: [String]
  let ready: Bool
  @State private var placement: Placement?

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: Placement?.self) { [eventIDs] proxy in
        guard !eventIDs.isEmpty, let scroll = proxy.bounds(of: .scrollView) else { return nil }
        return Placement(frame: proxy.frame(in: .scrollView), container: scroll.size)
      } action: { placement = $0 }
      .onChange(
        of: Report(chat: chat, placement: placement, eventIDs: eventIDs, ready: ready), initial: true
      ) { _, report in
        guard let chat = report.chat else { return }
        guard let placement = report.placement, !report.eventIDs.isEmpty else {
          return model.chatAttention.removeSurface(key, of: chat)
        }
        model.chatAttention.setSurface(
          key, of: chat, frame: placement.frame, container: placement.container,
          eventIDs: report.eventIDs, ready: report.ready)
      }
      .onDisappear {
        if let chat { model.chatAttention.removeSurface(key, of: chat) }
      }
  }
}
