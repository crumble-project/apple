import Foundation

/// How a provider credential is set: an API key, or an account sign-in.
public enum ProviderAuthType: String, Codable, Hashable, Sendable {
  case apiKey = "api_key"
  case oauth
}

/// A sign-in the provider can run interactively. Ambient-only providers offer none.
public struct ProviderLoginMethod: Codable, Hashable, Sendable {
  public var type: ProviderAuthType
  public var label: String
  /// Backed by a provider subscription, such as ChatGPT Plus.
  public var subscription: Bool

  public init(type: ProviderAuthType, label: String, subscription: Bool = false) {
    self.type = type
    self.label = label
    self.subscription = subscription
  }
}

public struct ProviderStatus: Codable, Hashable, Sendable {
  public var provider: String
  public var name: String?
  /// Saved or ambient credentials make the provider usable.
  public var configured: Bool
  public var authMethods: [ProviderLoginMethod]
  /// The saved credential; ambient credentials, such as environment variables, have none.
  public var credentialType: ProviderAuthType?
  /// A sign-in running on the server, to resume after reconnecting.
  public var activeLoginId: String?

  public init(
    provider: String,
    name: String? = nil,
    configured: Bool,
    authMethods: [ProviderLoginMethod] = [],
    credentialType: ProviderAuthType? = nil,
    activeLoginId: String? = nil
  ) {
    self.provider = provider
    self.name = name
    self.configured = configured
    self.authMethods = authMethods
    self.credentialType = credentialType
    self.activeLoginId = activeLoginId
  }
}

/// A provider sign-in running on the server. The server keeps it while the client disconnects, and ends it
/// after 10 minutes without an answer, 30 minutes in total, or a restart.
public struct ProviderLogin: Identifiable, Hashable, Sendable {
  public enum Status: String, Hashable, Sendable {
    case pending, succeeded, failed, cancelled, expired
  }

  public struct Option: Hashable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
  }

  public enum PromptKind: Hashable, Sendable {
    case text, secret, select
    /// A code or the full address the browser ended on, pasted by the owner.
    case manualCode
  }

  /// A question the provider waits on. Answer a `select` with an option's `id`.
  public struct Prompt: Hashable, Sendable {
    public var id: String
    public var kind: PromptKind
    public var message: String
    public var placeholder: String?
    public var options: [Option]
  }

  public struct Link: Hashable, Sendable {
    public var url: URL
    public var label: String?
  }

  public enum Event: Hashable, Sendable {
    case info(message: String, links: [Link])
    /// Open only on the owner's request.
    case authorization(url: URL, instructions: String?)
    case deviceCode(userCode: String, verificationURL: URL, expiresIn: TimeInterval?)
    case progress(String)
  }

  public var id: String
  public var provider: String
  public var method: ProviderAuthType
  public var status: Status
  public var expiresAt: Date
  public var prompt: Prompt?
  public var events: [Event]
  /// Why the sign-in failed, ready to show.
  public var failure: String?

  public var isPending: Bool { status == .pending }

  /// What the owner acts on in the browser: the latest authorization link or device code.
  public var browserStep: Event? {
    events.last {
      switch $0 {
      case .authorization, .deviceCode: true
      case .info, .progress: false
      }
    }
  }

  init(wire: Components.Schemas.ProviderLoginSession) {
    id = wire.id
    provider = wire.provider
    method = wire.method == .oauth ? .oauth : .apiKey
    status = Status(rawValue: wire.status.rawValue) ?? .failed
    expiresAt = Date(timeIntervalSince1970: wire.expiresAt / 1000)
    prompt = wire.prompt.map { prompt in
      let kind: PromptKind = switch prompt._type {
      case .text: .text
      case .secret: .secret
      case .select: .select
      case .manualCode: .manualCode
      }
      return Prompt(
        id: prompt.id, kind: kind,
        message: prompt.message, placeholder: prompt.placeholder,
        options: (prompt.options ?? []).map { Option(id: $0.id, label: $0.label, description: $0.description) })
    }
    events = wire.events.compactMap { event in
      switch event {
      case let .case1(info):
        .info(
          message: info.message,
          links: (info.links ?? []).compactMap { link in
            URL(string: link.url).map { Link(url: $0, label: link.label) }
          })
      case let .case2(authorization):
        URL(string: authorization.url).map { .authorization(url: $0, instructions: authorization.instructions) }
      case let .case3(device):
        URL(string: device.verificationUri).map {
          .deviceCode(userCode: device.userCode, verificationURL: $0, expiresIn: device.expiresInSeconds)
        }
      case let .case4(progress):
        .progress(progress.message)
      }
    }
    failure = wire.failure?.message
  }
}

extension APIClient {
  /// Starts a sign-in on the server. A second sign-in for the same provider fails with 409 while one runs.
  public func startProviderLogin(_ provider: String, method: ProviderAuthType) async throws -> ProviderLogin {
    try await invoke {
      ProviderLogin(wire: try await $0.startProviderLogin(.init(
        path: .init(provider: provider), body: .json(.init(method: method == .oauth ? .oauth : .apiKey))
      )).accepted.body.json)
    }
  }

  /// The sign-in's current state. Fails with 410 once the server no longer knows it, such as after a restart.
  public func providerLogin(_ id: String) async throws -> ProviderLogin {
    try await invoke { ProviderLogin(wire: try await $0.getProviderLogin(.init(path: .init(id: id))).ok.body.json) }
  }

  /// Answers the outstanding prompt. A withdrawn or already answered prompt fails with 409.
  public func answerProviderLogin(_ id: String, promptID: String, value: String) async throws -> ProviderLogin {
    try await invoke {
      ProviderLogin(wire: try await $0.answerProviderLogin(.init(
        path: .init(id: id), body: .json(.init(promptId: promptID, value: value))
      )).ok.body.json)
    }
  }

  public func cancelProviderLogin(_ id: String) async throws -> ProviderLogin {
    try await invoke {
      ProviderLogin(wire: try await $0.cancelProviderLogin(.init(path: .init(id: id))).ok.body.json)
    }
  }
}
