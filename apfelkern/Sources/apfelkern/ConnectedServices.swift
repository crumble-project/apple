import Foundation

/// A server's connection to a service outside Crumble.
public enum ServiceConnection: String, Hashable, Sendable {
  case disconnected, connecting, connected, error
}

public enum PluginContribution: String, Hashable, Sendable {
  case providers, jobKinds, webSearchProviders, chatAdapters
}

/// A plugin's secret setting. Its value is never returned, only how it's stored.
public struct PluginSetting: Identifiable, Hashable, Sendable {
  public var pluginID: String
  public var key: String
  public var label: String
  public var contributes: Set<PluginContribution>
  public var secret: SecretStatus

  public var id: String { pluginID + ":" + key }

  public init(
    pluginID: String, key: String, label: String, contributes: Set<PluginContribution> = [], secret: SecretStatus
  ) {
    self.pluginID = pluginID
    self.key = key
    self.label = label
    self.contributes = contributes
    self.secret = secret
  }
}

/// Which plugin settings a page shows.
public enum PluginSettingSelection: Hashable, Sendable {
  case contributes(PluginContribution)
  case plugin(String)
  case secretKey(String)

  /// The plugin that runs the event relay.
  public static let eventRelay = PluginSettingSelection.plugin("doorstep")

  func matches(_ setting: PluginSetting) -> Bool {
    switch self {
    case .contributes(let contribution): setting.contributes.contains(contribution)
    case .plugin(let id): setting.pluginID == id
    case .secretKey(let key): setting.id == key
    }
  }
}

/// The editor for a plugin setting. The value stays write-only: it leaves only in a save request.
public struct PluginSettingDraft: Identifiable, Sendable {
  public let id = UUID()
  public let setting: PluginSetting
  public var source: SecretSourceDraft

  public init(setting: PluginSetting) {
    self.setting = setting
    source = SecretSourceDraft(saved: setting.secret)
  }

  public var isReady: Bool { source.changedInput != nil }

  mutating func clearSecrets() { source.clear() }
}

extension PluginSettingDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "PluginSettingDraft(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The editor for a password manager's token. The token stays write-only: it leaves only in a save
/// request.
public struct PasswordManagerDraft: Identifiable, Sendable {
  public let id = UUID()
  public let manager: PasswordManager
  public var token = ""

  public init(manager: PasswordManager) { self.manager = manager }

  public var title: String { manager.connected ? "Replace \(manager.name) token" : "Connect \(manager.name)" }
  public var saveLabel: String { manager.connected ? "Save" : "Connect" }
  public var isReady: Bool { !trimmedToken.isEmpty }

  public var note: String {
    "Crumble signs in once to check the token and stores it encrypted. It only reads secrets you point it at."
  }

  var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

  mutating func clearSecrets() { token = "" }
}

extension PasswordManagerDraft: CustomStringConvertible, CustomReflectable {
  public var description: String { "PasswordManagerDraft(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The account's event relay. The Doorstep account token is a plugin setting.
public struct EventRelay: Hashable, Sendable {
  public var url: String?
  public var tokenConfigured: Bool
  public var status: ServiceConnection
  public var error: String?

  public init(url: String?, tokenConfigured: Bool, status: ServiceConnection, error: String? = nil) {
    self.url = url
    self.tokenConfigured = tokenConfigured
    self.status = status
    self.error = error
  }

  public var statusLabel: String {
    switch status {
    case .disconnected: "Not set up"
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .error: "Connection error"
    }
  }
}
