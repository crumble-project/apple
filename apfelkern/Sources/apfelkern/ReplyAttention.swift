import CoreGraphics
import Foundation

/// A bot or group chat as chat attention names it. Bot and group IDs are separate namespaces, so a group's member
/// bot chat is not the group chat.
public struct ChatAttentionChat: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case bot
    case group
  }

  public var kind: Kind
  public var id: String

  public init(kind: Kind, id: String) {
    self.kind = kind
    self.id = id
  }

  public static func bot(_ id: String) -> Self { Self(kind: .bot, id: id) }
  public static func group(_ id: String) -> Self { Self(kind: .group, id: id) }
}

extension Route {
  /// The chat this route shows; panels show none.
  public var attentionChat: ChatAttentionChat? {
    switch self {
    case .agent(let id): .bot(id)
    case .group(let id): .group(id)
    default: nil
    }
  }
}

extension ActivityEvent {
  /// The chat a reply belongs to: its group when it has one, otherwise its bot's chat.
  public var attentionChat: ChatAttentionChat {
    groupId?.nilIfEmpty.map(ChatAttentionChat.group) ?? .bot(agentId)
  }
}

/// The rendered part of a message whose display acknowledges a reply.
public enum ReplySurface: Hashable, Sendable {
  /// The reply's text, without its citations.
  case text
  /// A waiting request card, named by its tool call.
  case toolCard(String)
  /// A held action's card, named by the action.
  case heldAction(String)
}

/// A notification reply event and the exact surface that shows it.
public struct ReplyReference: Codable, Hashable, Sendable {
  typealias Wire = Components.Schemas.TranscriptMessage.ReplyReferencesPayloadPayload

  public var eventId: String
  public var surface: ReplySurface

  public init(eventId: String, surface: ReplySurface) {
    self.eventId = eventId
    self.surface = surface
  }

  init(wire: Wire) {
    eventId = wire.eventId
    surface = switch wire.surface {
    case .case1: .text
    case .case2(let card): .toolCard(card.toolCallId)
    case .case3(let held): .heldAction(held.actionId)
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(wire: try Wire(from: decoder))
  }

  public func encode(to encoder: Encoder) throws {
    let surface: Wire.SurfacePayload = switch self.surface {
    case .text: .case1(.init(kind: .text))
    case .toolCard(let id): .case2(.init(kind: .toolCard, toolCallId: id))
    case .heldAction(let id): .case3(.init(actionId: id, kind: .heldAction))
    }
    try Wire(eventId: eventId, surface: surface).encode(to: encoder)
  }
}

extension Message {
  /// The events this exact surface acknowledges once the owner sees it, each once.
  public func attentionEventIDs(for surface: ReplySurface) -> [String] {
    var seen = Set<String>()
    return replyReferences.filter { $0.surface == surface }.map(\.eventId).filter { seen.insert($0).inserted }
  }

  /// A bot's reply text, once it has words to read; citations alone don't count.
  public var showsReplyText: Bool {
    role == "assistant" && !presentedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The waiting card a reply reference can name, and whether the card shows its server state rather than a
  /// placeholder. A loading or unavailable card isn't ready; a settled one the server confirmed is.
  @MainActor public func replyCard(
    heldActions: HeldActionBoard, botRequests: BotRequestBoard, callRequests: CallRequestBoard,
    botSecrets: BotSecretBoard
  ) -> (surface: ReplySurface, ready: Bool)? {
    if kind == HeldActionEvent.messageKind, let held = heldAction {
      return (.heldAction(held.id), heldActions.isReady(held.id))
    }
    guard role == "toolResult", let toolCallId = toolCallId?.nilIfEmpty else { return nil }
    if let request = BotRequest(message: self) { return (.toolCard(toolCallId), botRequests.isLoaded(request.id)) }
    if let request = CallRequest(message: self) { return (.toolCard(toolCallId), callRequests.isLoaded(request.id)) }
    if let ask = BotSecretAsk(message: self) { return (.toolCard(toolCallId), botSecrets.isReady(ask)) }
    return nil
  }
}

/// True when a ready surface has some area inside the chat's viewport. Touching its edge isn't enough.
public func replySurfaceVisible(ready: Bool, frame: CGRect, viewport: CGRect) -> Bool {
  guard ready else { return false }
  let shown = frame.intersection(viewport)
  return !shown.isNull && shown.width > 0 && shown.height > 0
}

/// The reply surfaces a chat has laid out, each framed in its scroll view's coordinates. A lazy list lays out only
/// rows near the screen, and a row that goes away takes its surfaces with it.
public struct ReplySurfaces: Sendable {
  private struct Key: Hashable {
    var chat: ChatAttentionChat
    var surface: String
  }

  private struct Surface {
    var frame: CGRect
    var container: CGSize
    var eventIDs: [String]
    var ready: Bool
  }

  /// What the toolbar and composer cover at the scroll view's top and bottom edges.
  private var top: CGFloat = 0
  private var bottom: CGFloat = 0
  private var surfaces: [Key: Surface] = [:]

  public init() {}

  public mutating func setInsets(top: CGFloat, bottom: CGFloat) {
    self.top = max(0, top)
    self.bottom = max(0, bottom)
  }

  /// A surface's frame and its scroll view's size, both in the scroll view's coordinates.
  public mutating func set(
    _ key: String, of chat: ChatAttentionChat, frame: CGRect, container: CGSize, eventIDs: [String], ready: Bool
  ) {
    surfaces[Key(chat: chat, surface: key)] = Surface(
      frame: frame, container: container, eventIDs: eventIDs, ready: ready)
  }

  public mutating func remove(_ key: String, of chat: ChatAttentionChat) {
    surfaces[Key(chat: chat, surface: key)] = nil
  }

  /// Forgets every other chat's surfaces.
  public mutating func keep(only chat: ChatAttentionChat?) {
    surfaces = surfaces.filter { $0.key.chat == chat }
  }

  /// Events whose ready surface shows in the uncovered part of the chat's scroll view, each once.
  public func visibleEventIDs(in chat: ChatAttentionChat) -> [String] {
    var seen = Set<String>()
    return surfaces.filter { $0.key.chat == chat }.values
      .filter { surface in
        let viewport = CGRect(
          x: 0, y: top, width: surface.container.width,
          height: max(0, surface.container.height - top - bottom))
        return replySurfaceVisible(ready: surface.ready, frame: surface.frame, viewport: viewport)
      }
      .flatMap(\.eventIDs)
      .filter { seen.insert($0).inserted }
  }
}
