import Foundation
import Observation

/// A sign-in credential on the account. Adding one needs WebAuthn; the apps only list, rename, and
/// remove, which need just a session.
public struct Passkey: Identifiable, Hashable, Sendable {
  public static let maxNameCharacters = 100

  public var id: String
  public var name: String?
  public var createdAt: String
  /// Synced across the owner's devices by their password manager.
  public var backedUp: Bool

  public init(id: String, name: String? = nil, createdAt: String, backedUp: Bool = false) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.backedUp = backedUp
  }

  public var title: String { name?.nilIfEmpty ?? "Passkey" }

  public var detail: String {
    let added = automationRunDate(createdAt).map { "Added " + $0.formatted(date: .numeric, time: .omitted) }
    return [added, backedUp ? "Synced" : nil].compactMap(\.self).joined(separator: " · ")
  }

  /// Passkeys are bound to the server's host name, as the web's page says.
  public static func footer(serverURL: String) -> String {
    let host = URL(string: serverURL)?.host() ?? "this server"
    return "Passkeys belong to \(host). They stop working if the server's address changes. "
      + "Add one in Crumble on the web."
  }
}

/// The account's passkeys. Renaming and removing apply at once and come back on failure. Results
/// that return after the connection changed are dropped.
@MainActor @Observable
public final class PasskeyBoard {
  private var loaded: [Passkey] = []
  public private(set) var isLoaded = false
  /// Why the last read, rename, or removal failed.
  public private(set) var error: String?
  private var order = ReadOrder()
  /// Hidden until the server answers, so a read can't bring them back.
  private var removing: Set<String> = []
  /// Shown until the server answers, so a read can't undo them.
  private var renaming: [String: String] = [:]
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    error = nil
    order = ReadOrder()
    removing = []
    renaming = [:]
  }

  public var passkeys: [Passkey] {
    loaded.filter { !removing.contains($0.id) }.map {
      var passkey = $0
      if let name = renaming[$0.id] { passkey.name = name }
      return passkey
    }
  }

  public func isBusy(_ id: String) -> Bool { renaming[id] != nil || removing.contains(id) }

  public func refresh(client: APIClient) {
    let version = scope
    let attempt = order.begin()
    let shownError = error
    Task {
      do {
        let passkeys = try await client.passkeys()
        guard scope == version, order.accept(attempt) else { return }
        loaded = passkeys
        isLoaded = true
        // A rename that failed during this read is news the read can't have settled.
        if error == shownError { error = nil }
      } catch {
        guard scope == version, order.accept(attempt) else { return }
        self.error = friendlyError(error)
      }
    }
  }

  public func rename(
    _ id: String, to name: String, client: APIClient, session: URLSession = URLSession(configuration: .ephemeral)
  ) {
    let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Passkey.maxNameCharacters))
    guard !trimmed.isEmpty, !isBusy(id), loaded.contains(where: { $0.id == id && $0.name != trimmed }) else { return }
    error = nil
    renaming[id] = trimmed
    let version = scope
    Task {
      do {
        try await client.renamePasskey(id, name: trimmed, session: session)
        guard scope == version else { return }
        if let index = loaded.firstIndex(where: { $0.id == id }) { loaded[index].name = trimmed }
      } catch {
        guard scope == version else { return }
        self.error = friendlyError(error)
      }
      renaming[id] = nil
    }
  }

  public func remove(_ id: String, client: APIClient, session: URLSession = URLSession(configuration: .ephemeral)) {
    guard !isBusy(id) else { return }
    error = nil
    removing.insert(id)
    let version = scope
    Task {
      do {
        try await client.removePasskey(id, session: session)
        guard scope == version else { return }
        loaded.removeAll { $0.id == id }
      } catch {
        guard scope == version else { return }
        self.error = friendlyError(error)
      }
      removing.remove(id)
    }
  }
}
