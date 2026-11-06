import Foundation

/// The signed-in account. The server names it only outside the `/v1` contract.
public struct ServerAccount: Hashable, Sendable {
  public var id: String
  public var isAdmin: Bool
}

public enum UserRole: String, Hashable, Sendable {
  case admin, user
}

/// An account on the server, as an admin sees it.
public struct AdminUser: Identifiable, Hashable, Sendable {
  public var id: String
  public var email: String
  public var name: String
  public var role: UserRole

  public var shown: String { name.isEmpty ? email : name }
  public var title: String { role == .admin ? "\(shown) (admin)" : shown }
  public var initial: String { String(shown.prefix(1)).uppercased() }
  public var removeWarning: String {
    "This removes the account, its sessions, and all its data, bots included. You can't undo this."
  }
}

extension AdminUser {
  init(wire: Components.Schemas.AdminUser) {
    self.init(
      id: wire.id, email: wire.email, name: wire.name, role: wire.role == .admin ? .admin : .user)
  }
}

/// An invite link not yet used or revoked. The server keeps only its hash, so the link isn't here.
public struct PendingInvite: Identifiable, Hashable, Sendable {
  public var id: String
  public var createdAt: Date?

  public var title: String {
    createdAt.map { "Invite from \($0.formatted(date: .numeric, time: .omitted))" } ?? "Invite"
  }
}

extension PendingInvite {
  init(wire: Components.Schemas.Invite) {
    self.init(
      id: wire.id, createdAt: try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(wire.createdAt))
  }
}

/// The sheet that shows a new invite link once. Anyone holding the link can make an account, so it
/// stays out of `description` and `dump`.
public struct InviteLinkSheet: Identifiable, Sendable {
  public let id = UUID()
  public var link: String?
  public var error: String?

  public var isPending: Bool { link == nil && error == nil }
}

extension InviteLinkSheet: CustomStringConvertible, CustomReflectable {
  public var description: String { "InviteLinkSheet(\(isPending ? "pending" : error == nil ? "ready" : "failed"))" }
  public var customMirror: Mirror { Mirror(self, children: ["isPending": isPending]) }
}

/// A running workspace whose machine has another image than the server's settings name.
public struct OutdatedWorkspace: Identifiable, Hashable, Sendable {
  public var userId: String
  public var agentId: String

  public var id: String { userId + "/" + agentId }
}

public struct ServerSettings: Hashable, Sendable {
  public static let mibPerGB = 1024
  static let cpuRange = 1...64
  static let memoryRange = 512...262_144
  static let graceRange = 0...1440

  public var signUpOpen: Bool
  public var workspaceCpus: Int
  public var workspaceMemoryMib: Int
  /// The image new workspaces boot from; nil uses the server's `CRUMBLE_WORKSPACE_IMAGE`.
  public var codingImage: String?
  public var questionGraceMinutes: Int

  /// The size in GB, as the web shows it: `4`, or `1.5` when it isn't whole.
  public var workspaceGigabytes: String {
    let gigabytes = Double(workspaceMemoryMib) / Double(Self.mibPerGB)
    return gigabytes == gigabytes.rounded() ? String(Int(gigabytes)) : String(gigabytes)
  }
}

extension ServerSettings {
  init(wire: Components.Schemas.ServerSettings) {
    self.init(
      signUpOpen: wire.signUpOpen, workspaceCpus: wire.workspaceCpus,
      workspaceMemoryMib: wire.workspaceMemoryMib, codingImage: wire.codingImage,
      questionGraceMinutes: wire.questionGraceMinutes)
  }
}

/// The settings a save changes. `codingImage` is `.some(nil)` to go back to the server's default.
public struct ServerSettingsPatch: Hashable, Sendable {
  public var signUpOpen: Bool?
  public var workspaceCpus: Int?
  public var workspaceMemoryMib: Int?
  public var codingImage: String??
  public var questionGraceMinutes: Int?

  func apply(to settings: inout ServerSettings) {
    if let signUpOpen { settings.signUpOpen = signUpOpen }
    if let workspaceCpus { settings.workspaceCpus = workspaceCpus }
    if let workspaceMemoryMib { settings.workspaceMemoryMib = workspaceMemoryMib }
    if let codingImage { settings.codingImage = codingImage }
    if let questionGraceMinutes { settings.questionGraceMinutes = questionGraceMinutes }
  }
}

/// The editor for one workspace setting. Fields hold text so a half-typed number survives.
public struct ServerSettingsDraft: Identifiable, Sendable {
  public enum Field: String, CaseIterable, Identifiable, Sendable {
    case size, image, grace

    public var id: Self { self }

    public var title: String {
      switch self {
      case .size: "Workspace size"
      case .image: "Coding image"
      case .grace: "Question grace period"
      }
    }

    public var symbol: String {
      switch self {
      case .size: "cpu"
      case .image: "shippingbox"
      case .grace: "clock"
      }
    }

    public func value(_ settings: ServerSettings) -> String {
      switch self {
      case .size: "\(settings.workspaceCpus) CPUs, \(settings.workspaceGigabytes) GB"
      case .image: settings.codingImage ?? "server default"
      case .grace: "\(settings.questionGraceMinutes) min"
      }
    }
  }

  public let id = UUID()
  public let field: Field
  public var cpus: String
  public var memory: String
  public var image: String
  public var grace: String

  public init(field: Field, settings: ServerSettings) {
    self.field = field
    cpus = String(settings.workspaceCpus)
    memory = settings.workspaceGigabytes
    image = settings.codingImage ?? ""
    grace = String(settings.questionGraceMinutes)
  }

  public var isReady: Bool { patch != nil }

  /// What the server would accept, or nil. Only the edited field's settings are sent.
  var patch: ServerSettingsPatch? {
    switch field {
    case .size:
      guard let cpus = Int(cpus), ServerSettings.cpuRange.contains(cpus), let memory = memoryMib else { return nil }
      return ServerSettingsPatch(workspaceCpus: cpus, workspaceMemoryMib: memory)
    case .image:
      let image = image.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !image.isEmpty else { return ServerSettingsPatch(codingImage: .some(nil)) }
      let valid = image.range(of: #"^[a-z0-9][A-Za-z0-9_.\-/:@]{0,254}$"#, options: .regularExpression) != nil
      return valid ? ServerSettingsPatch(codingImage: image) : nil
    case .grace:
      guard let grace = Int(grace), ServerSettings.graceRange.contains(grace) else { return nil }
      return ServerSettingsPatch(questionGraceMinutes: grace)
    }
  }

  /// A comma counts as a decimal point: that is what a German number pad types.
  private var memoryMib: Int? {
    guard let gigabytes = Double(memory.replacingOccurrences(of: ",", with: ".")), gigabytes.isFinite,
          gigabytes > 0, gigabytes * Double(ServerSettings.mibPerGB) <= Double(ServerSettings.memoryRange.upperBound)
    else { return nil }
    let mib = Int((gigabytes * Double(ServerSettings.mibPerGB)).rounded())
    return ServerSettings.memoryRange.contains(mib) ? mib : nil
  }
}

extension ServerCapabilities {
  /// What the server's operator has to set for each capability it lacks.
  public var missingNotes: [String] {
    var notes: [String] = []
    if !coding { notes.append("Coding jobs need CRUMBLE_WORKSPACE_IMAGE on the server.") }
    if !desktop { notes.append("Desktop jobs need CRUMBLE_WORKSPACE_DESKTOP_IMAGE on the server.") }
    return notes
  }
}
