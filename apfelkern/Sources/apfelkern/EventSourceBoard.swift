import Foundation
import Observation

/// One webhook address on the event relay. Its secret address is returned only when it's created.
public struct EventSource: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var usedBy: Int

  public init(id: String, name: String, usedBy: Int = 0) {
    self.id = id
    self.name = name
    self.usedBy = usedBy
  }

  public var usedByLabel: String { "used by \(usedBy)" }
  public var canDelete: Bool { usedBy == 0 }
  public var deleteNote: String { canDelete ? "Delete" : "Remove the automations that use it first" }
}

/// A new source and the address the server returns once.
public struct CreatedEventSource: Sendable {
  public var source: EventSource
  public var address: String

  public init(source: EventSource, address: String) {
    self.source = source
    self.address = address
  }
}

extension CreatedEventSource: CustomStringConvertible, CustomReflectable {
  public var description: String { "CreatedEventSource(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The sheet that adds a source, then shows its address. The address lives only here.
public struct EventSourceDraft: Identifiable, Sendable {
  public static let maxNameCharacters = 200

  public let id = UUID()
  public var name = "" {
    didSet { if name.count > Self.maxNameCharacters { name = String(name.prefix(Self.maxNameCharacters)) } }
  }
  public fileprivate(set) var created: CreatedEventSource?

  public init() {}

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension EventSourceDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "EventSourceDraft(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The account's event sources. Creating depends on the relay, so the sheet holds until the server
/// answers and then shows the address once. Deleting applies at once and comes back on failure.
/// Results that return after the connection changed are dropped.
@MainActor @Observable
public final class EventSourceBoard {
  private var loaded: [EventSource] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var order = ReadOrder()
  /// Hidden until the server answers, so a read can't bring them back.
  private var deleting: Set<String> = []
  /// Why deleting failed, by source.
  public private(set) var errors: [String: String] = [:]

  /// The open sheet.
  public var draft: EventSourceDraft?
  public private(set) var isSaving = false
  public private(set) var saveError = ""
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    readError = nil
    order = ReadOrder()
    deleting = []
    errors = [:]
    isSaving = false
    closeDraft()
  }

  public var sources: [EventSource] { loaded.filter { !deleting.contains($0.id) } }

  public var canSave: Bool { draft?.trimmedName.isEmpty == false && draft?.created == nil && !isSaving }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      do {
        let sources = try await client.eventSources()
        guard scope == version, order.accept(read) else { return }
        loaded = sources
        isLoaded = true
        readError = nil
      } catch {
        guard scope == version, order.accept(read) else { return }
        readError = friendlyError(error)
      }
    }
  }

  /// Never replaces an open sheet: it may hold an address that can't be shown again.
  public func open() {
    guard draft == nil else { return }
    draft = EventSourceDraft()
  }

  /// Closing forgets the address.
  public func closeDraft() {
    guard !isSaving else { return }
    draft = nil
    saveError = ""
  }

  public func saveDraft(client: APIClient) {
    guard canSave, let draft else { return }
    let version = scope
    saveError = ""
    isSaving = true
    Task {
      do {
        let created = try await client.createEventSource(name: draft.trimmedName)
        guard scope == version else { return }
        order.settle()
        loaded.append(created.source)
        isSaving = false
        self.draft?.created = created
      } catch {
        guard scope == version else { return }
        isSaving = false
        saveError = friendlyError(error)
      }
      refresh(client: client)
    }
  }

  public func delete(_ source: EventSource, client: APIClient) {
    guard source.canDelete, deleting.insert(source.id).inserted else { return }
    errors[source.id] = nil
    let version = scope
    Task {
      do {
        try await client.deleteEventSource(source.id)
        guard scope == version else { return }
        loaded.removeAll { $0.id == source.id }
      } catch {
        guard scope == version else { return }
        errors[source.id] = friendlyError(error)
      }
      order.settle()
      deleting.remove(source.id)
      refresh(client: client)
    }
  }
}
