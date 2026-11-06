import Foundation
import Observation

/// One account setting. A choice shows at once and comes back on failure. Writes run one at a time and
/// only the newest choice waits, so the server ends on what the owner chose last. Results that return
/// after the connection changed are dropped.
@MainActor @Observable
public final class AccountSettingBoard<Setting: AccountSetting> {
  /// Wraps the choice because a model setting's own choice can be nil.
  private struct Wanted {
    let choice: Setting.Choice
  }

  private var loaded: Setting?
  public private(set) var readError: String?
  /// Why the last choice didn't save.
  public private(set) var saveError: String?
  private var order = ReadOrder()
  /// Shown over `loaded` until the server answers, so a read can't take it away.
  private var wanted: Wanted?
  private var isWriting = false
  private var scope = 0
  private let read: @MainActor (APIClient) async throws -> Setting
  private let save: @MainActor (APIClient, Setting.Choice) async throws -> Setting

  public init(
    read: @escaping @MainActor (APIClient) async throws -> Setting,
    save: @escaping @MainActor (APIClient, Setting.Choice) async throws -> Setting
  ) {
    self.read = read
    self.save = save
  }

  public var setting: Setting? {
    guard var shown = loaded else { return nil }
    if let wanted { shown.choice = wanted.choice }
    return shown
  }

  public func reset() {
    scope += 1
    loaded = nil
    readError = nil
    saveError = nil
    order = ReadOrder()
    wanted = nil
    isWriting = false
  }

  public func refresh(client: APIClient) {
    let version = scope
    let attempt = order.begin()
    Task {
      do {
        let setting = try await read(client)
        guard scope == version, order.accept(attempt) else { return }
        loaded = setting
        readError = nil
      } catch {
        guard scope == version, order.accept(attempt) else { return }
        readError = friendlyError(error)
      }
    }
  }

  public func choose(_ choice: Setting.Choice, client: APIClient) {
    guard let shown = setting, shown.choice != choice else { return }
    saveError = nil
    wanted = Wanted(choice: choice)
    if !isWriting { write(choice, client: client) }
  }

  private func write(_ choice: Setting.Choice, client: APIClient) {
    isWriting = true
    let version = scope
    Task {
      var failed = false
      do {
        let saved = try await save(client, choice)
        guard scope == version else { return }
        loaded = saved
      } catch {
        guard scope == version else { return }
        failed = true
        if wanted?.choice == choice { saveError = friendlyError(error) }
      }
      order.settle()
      isWriting = false
      if let wanted, wanted.choice != choice {
        write(wanted.choice, client: client)
      } else {
        wanted = nil
        if failed { refresh(client: client) }
      }
    }
  }
}
