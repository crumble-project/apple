import Foundation
import Observation

/// Orders a board's reads: one that predates a newer read or a write is ignored.
struct ReadOrder {
  private var started = 0
  private var settled = 0

  mutating func begin() -> Int {
    started += 1
    return started
  }

  mutating func accept(_ read: Int) -> Bool {
    guard read > settled else { return false }
    settled = read
    return true
  }

  mutating func settle() { settled = started }
}

/// The account's connected services, the settings that choose among them, and what each change means
/// for the others.
@MainActor
public final class ConnectedServices {
  public let passwordManagers = PasswordManagerBoard()
  public let pluginSettings = PluginSettingBoard()
  public let gateways: MessageGatewayBoard
  public let relay: EventRelayBoard
  public let eventSources = EventSourceBoard()
  public let webSearch: AccountSettingBoard<WebSearchSettings>
  public let judgeModel: AccountSettingBoard<JudgeModelSettings>
  public let visionModel: AccountSettingBoard<VisionModelSettings>

  public init(gatewayPoll: Duration = .seconds(5), relayPoll: Duration = .seconds(1)) {
    gateways = MessageGatewayBoard(pollInterval: gatewayPoll)
    relay = EventRelayBoard(pollInterval: relayPoll)
    webSearch = AccountSettingBoard(
      read: { try await $0.webSearch() }, save: { try await $0.updateWebSearch(defaultProvider: $1) })
    judgeModel = AccountSettingBoard(
      read: { try await $0.judgeModel() }, save: { try await $0.updateJudgeModel($1) })
    visionModel = AccountSettingBoard(
      read: { try await $0.visionModel() }, save: { try await $0.updateVisionModel($1) })
    // A token decides whether a connection can run, and a reference counts as a use of its manager.
    pluginSettings.onChange = { [passwordManagers, gateways, relay, eventSources, webSearch] client in
      passwordManagers.refresh(client: client)
      gateways.refresh(client: client)
      relay.refresh(client: client)
      eventSources.refresh(client: client)
      webSearch.refresh(client: client)
    }
  }

  public func reset() {
    passwordManagers.reset()
    pluginSettings.reset()
    gateways.reset()
    relay.reset()
    eventSources.reset()
    webSearch.reset()
    judgeModel.reset()
    visionModel.reset()
  }

  /// The models a setting can choose depend on the account's provider keys.
  public func refreshModelChoices(client: APIClient) {
    judgeModel.refresh(client: client)
    visionModel.refresh(client: client)
  }

  /// Reads what a page shows.
  public func refresh(_ route: Route, client: APIClient) {
    if route == .judgeModel { return judgeModel.refresh(client: client) }
    if route == .visionModel { return visionModel.refresh(client: client) }
    passwordManagers.refresh(client: client)
    switch route {
    case .webSearch:
      webSearch.refresh(client: client)
      pluginSettings.refresh(client: client)
    case .messageGateways:
      pluginSettings.refresh(client: client)
      gateways.refresh(client: client)
    case .eventRelay:
      pluginSettings.refresh(client: client)
      relay.refresh(client: client)
      eventSources.refresh(client: client)
    default:
      break
    }
  }
}

/// The password managers this server supports. A token depends on the password manager, so its
/// sheet holds until the server answers. Disconnecting applies at once and comes back on failure.
/// Results that return after the connection changed are dropped.
@MainActor @Observable
public final class PasswordManagerBoard {
  private var loaded: [PasswordManager] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var order = ReadOrder()
  /// Shown as disconnected until the server answers, so a read can't bring them back.
  private var disconnecting: Set<PasswordManagerID> = []
  /// Why disconnecting failed.
  public private(set) var errors: [PasswordManagerID: String] = [:]

  /// The open sheet. Only here and in a save in flight does a typed token live.
  public var draft: PasswordManagerDraft?
  /// The token is with the password manager, so the sheet can't close until the server answers.
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
    disconnecting = []
    errors = [:]
    isSaving = false
    closeDraft()
  }

  public var managers: [PasswordManager] {
    loaded.map { manager in
      var shown = manager
      if disconnecting.contains(manager.id) { shown.connected = false }
      return shown
    }
  }

  /// What a secret can read from. `known` stands in until this board has read the server.
  public func connected(knownUntilLoaded known: [PasswordManager]) -> [PasswordManager] {
    isLoaded ? managers.filter(\.connected) : known
  }

  public func isUnconfirmed(_ manager: PasswordManager) -> Bool { disconnecting.contains(manager.id) }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      do {
        let managers = try await client.passwordManagers()
        guard scope == version, order.accept(read) else { return }
        loaded = managers
        isLoaded = true
        readError = nil
      } catch {
        guard scope == version, order.accept(read) else { return }
        readError = friendlyError(error)
      }
    }
  }

  /// Never replaces an open sheet: it may hold a typed token.
  public func open(_ manager: PasswordManager) {
    guard draft == nil, !isUnconfirmed(manager) else { return }
    draft = PasswordManagerDraft(manager: manager)
  }

  public var canSave: Bool { draft?.isReady == true && !isSaving }

  public func closeDraft() {
    guard !isSaving else { return }
    draft?.clearSecrets()
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
        let saved = try await client.connectPasswordManager(draft.manager.id, token: draft.trimmedToken)
        guard scope == version else { return }
        order.settle()
        if let index = loaded.firstIndex(where: { $0.id == saved.id }) { loaded[index] = saved }
        isSaving = false
        closeDraft()
      } catch {
        guard scope == version else { return }
        isSaving = false
        saveError = friendlyError(error)
      }
      refresh(client: client)
    }
  }

  public func disconnect(_ manager: PasswordManager, client: APIClient) {
    guard manager.connected, manager.usedBy.isEmpty, disconnecting.insert(manager.id).inserted else { return }
    errors[manager.id] = nil
    let version = scope
    Task {
      do {
        try await client.disconnectPasswordManager(manager.id)
        guard scope == version else { return }
        if let index = loaded.firstIndex(where: { $0.id == manager.id }) { loaded[index].connected = false }
      } catch {
        guard scope == version else { return }
        errors[manager.id] = friendlyError(error)
      }
      order.settle()
      disconnecting.remove(manager.id)
      refresh(client: client)
    }
  }
}

/// Plugin settings. Saving a value and removing apply at once and come back on failure, the failed
/// save with what the owner typed. A password manager check holds the sheet until the server
/// answers. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class PluginSettingBoard {
  private var loaded: [PluginSetting] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var order = ReadOrder()
  /// What to show for a setting until the server answers, so a read can't take it away.
  private var saving: [String: SecretStatus] = [:]
  /// Why removing failed, by setting.
  public private(set) var errors: [String: String] = [:]

  /// The open sheet. Only here, in a save in flight, and in `returned` does a typed value live.
  public var draft: PluginSettingDraft?
  /// Failed saves waiting for the open sheet to close.
  private var returned: [(draft: PluginSettingDraft, error: String)] = []
  /// The open sheet's reference is with a password manager, so it can't close until the server answers.
  public private(set) var isSaving = false
  public private(set) var saveError = ""
  /// Runs after the server took a change.
  var onChange: ((APIClient) -> Void)?
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    readError = nil
    order = ReadOrder()
    saving = [:]
    errors = [:]
    returned = []
    isSaving = false
    closeDraft()
  }

  public func settings(_ selection: PluginSettingSelection) -> [PluginSetting] {
    loaded.filter(selection.matches).map { setting in
      var shown = setting
      if let status = saving[setting.id] { shown.secret = status }
      return shown
    }
  }

  public func isUnconfirmed(_ setting: PluginSetting) -> Bool { saving[setting.id] != nil }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      do {
        let settings = try await client.pluginSettings()
        guard scope == version, order.accept(read) else { return }
        loaded = settings
        isLoaded = true
        readError = nil
      } catch {
        guard scope == version, order.accept(read) else { return }
        readError = friendlyError(error)
      }
    }
  }

  /// Never replaces an open sheet: it may hold a typed value, or a save that came back.
  public func edit(_ setting: PluginSetting) {
    guard draft == nil, !isUnconfirmed(setting) else { return }
    draft = PluginSettingDraft(setting: setting)
  }

  public var canSave: Bool { draft?.isReady == true && !isSaving }

  public func closeDraft() {
    guard !isSaving else { return }
    draft?.clearSecrets()
    draft = nil
    saveError = ""
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  public func saveDraft(client: APIClient) {
    guard canSave, let draft, let input = draft.source.changedInput else { return }
    saveError = ""
    if draft.source.changesReference {
      saveAfterCheck(draft, input: input, client: client)
    } else {
      saveAtOnce(draft, input: input, client: client)
    }
  }

  private func saveAfterCheck(_ draft: PluginSettingDraft, input: SecretInput, client: APIClient) {
    let version = scope
    isSaving = true
    Task {
      do {
        let saved = try await client.setPluginSetting(draft.setting, to: input)
        guard scope == version else { return }
        store(saved)
        isSaving = false
        closeDraft()
        changed(client: client)
      } catch {
        guard scope == version else { return }
        isSaving = false
        saveError = friendlyError(error)
      }
    }
  }

  private func saveAtOnce(_ draft: PluginSettingDraft, input: SecretInput, client: APIClient) {
    let version = scope
    let id = draft.setting.id
    saving[id] = SecretStatus(configured: true)
    closeDraft()
    Task {
      do {
        let saved = try await client.setPluginSetting(draft.setting, to: input)
        guard scope == version else { return }
        store(saved)
      } catch {
        guard scope == version else { return }
        order.settle()
        giveBack(draft, error: friendlyError(error))
      }
      saving[id] = nil
      changed(client: client)
    }
  }

  private func giveBack(_ failed: PluginSettingDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }

  public func remove(_ setting: PluginSetting, client: APIClient) {
    guard !isUnconfirmed(setting) else { return }
    let version = scope
    errors[setting.id] = nil
    saving[setting.id] = SecretStatus(configured: false)
    Task {
      do {
        let saved = try await client.deletePluginSetting(setting)
        guard scope == version else { return }
        store(saved)
      } catch {
        guard scope == version else { return }
        order.settle()
        errors[setting.id] = friendlyError(error)
      }
      saving[setting.id] = nil
      changed(client: client)
    }
  }

  private func store(_ saved: PluginSetting) {
    order.settle()
    if let index = loaded.firstIndex(where: { $0.id == saved.id }) { loaded[index] = saved }
  }

  private func changed(client: APIClient) {
    refresh(client: client)
    onChange?(client)
  }
}
