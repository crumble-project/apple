import Foundation

/// The server's web search providers.
public enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case mixed, exa

  public var id: Self { self }

  public var name: String {
    switch self {
    case .mixed: "Mixed"
    case .exa: "Exa"
    }
  }
}

/// A setting the server keeps for the account, with the one value the owner chooses in it.
public protocol AccountSetting: Sendable {
  associatedtype Choice: Equatable & Sendable
  var choice: Choice { get set }
}

public struct WebSearchSettings: AccountSetting, Hashable {
  public var defaultProvider: WebSearchProvider
  public var exaKeyConfigured: Bool

  public init(defaultProvider: WebSearchProvider, exaKeyConfigured: Bool) {
    self.defaultProvider = defaultProvider
    self.exaKeyConfigured = exaKeyConfigured
  }

  public var choice: WebSearchProvider {
    get { defaultProvider }
    set { defaultProvider = newValue }
  }

  /// Why the default can't search yet.
  public var warning: String? {
    defaultProvider == .exa && !exaKeyConfigured ? "Exa needs a key before bots can search with it." : nil
  }
}

/// A provider's model, as an account setting names it.
public struct ModelRef: Hashable, Sendable {
  public var provider: String
  public var model: String

  public init(provider: String, model: String) {
    self.provider = provider
    self.model = model
  }
}

/// A model the account's provider keys reach.
public struct ModelChoice: Identifiable, Hashable, Sendable {
  public var ref: ModelRef
  public var name: String

  public var id: ModelRef { ref }

  public init(ref: ModelRef, name: String) {
    self.ref = ref
    self.name = name
  }
}

/// An account setting that picks a model from those the provider keys reach.
public protocol ModelSetting: AccountSetting where Choice == ModelRef? {
  static var title: String { get }
  static var symbol: String { get }
  static var sectionTitle: String { get }
  static var sectionNote: String { get }
  static var unsetLabel: String { get }
  var choices: [ModelChoice] { get }
  var status: String { get }
}

extension ModelSetting {
  /// What a picker lists. A chosen model no key reaches any more stays listed, so the picker can show it.
  public var options: [ModelOption] {
    var options = [ModelOption(ref: nil, label: Self.unsetLabel)]
    options += choices.map { ModelOption(ref: $0.ref, label: $0.name) }
    if let chosen = choice, !choices.contains(where: { $0.ref == chosen }) {
      options.append(ModelOption(ref: chosen, label: "\(chosen.model) (no key)"))
    }
    return options
  }
}

public struct ModelOption: Identifiable, Hashable, Sendable {
  public var ref: ModelRef?
  public var label: String

  public var id: ModelRef? { ref }
}

public enum JudgeKind: String, Hashable, Sendable {
  case classifier, chat
}

public struct JudgeChoice: Hashable, Sendable {
  public var choice: ModelChoice
  public var kind: JudgeKind

  public init(choice: ModelChoice, kind: JudgeKind) {
    self.choice = choice
    self.kind = kind
  }
}

public struct JudgeModelSettings: ModelSetting, Hashable {
  /// The account's classifier; nil uses the default.
  public var judgeModel: ModelRef?
  /// What judges now; nil when no model is available.
  public var effective: JudgeChoice?
  public var judgeChoices: [JudgeChoice]

  public static let title = "Judge model"
  public static let symbol = "scale.3d"
  public static let sectionTitle = "Intent checks"
  public static let sectionNote =
    "Before a desktop job clicks, types, or presses a key, this model checks whether the action is irreversible "
    + "and whether you asked for it. Actions it can't clear wait for your approval in the bot's chat."
  public static let unsetLabel = "Default (\(defaultName))"
  private static let defaultName = "GPT-6 Luna"

  public init(judgeModel: ModelRef?, effective: JudgeChoice?, choices: [JudgeChoice]) {
    self.judgeModel = judgeModel
    self.effective = effective
    judgeChoices = choices
  }

  public var choice: ModelRef? {
    get { judgeModel }
    set {
      judgeModel = newValue
      if let next = judgeChoices.first(where: { $0.choice.ref == newValue }) { effective = next }
    }
  }

  public var choices: [ModelChoice] { judgeChoices.map(\.choice) }

  public var status: String {
    guard let effective else {
      return "No model is available, so only commit points such as Pay or Send are held. "
        + "Add an OpenAI API key for \(Self.defaultName)."
    }
    return effective.kind == .chat
      ? "\(effective.choice.name) judges as a chat model: no provider key reaches a classifier."
      : "\(effective.choice.name) judges now."
  }
}

public struct VisionModelSettings: ModelSetting, Hashable {
  /// Nil when off.
  public var visionModel: ModelRef?
  public var choices: [ModelChoice]

  public static let title = "Vision model"
  public static let symbol = "eye"
  public static let sectionTitle = "Images for text-only models"
  public static let sectionNote =
    "When a bot's model can't read images, this model describes each image it gets, including any visible text, "
    + "and the bot works from the description. The bot can also ask it questions about an image. Its tokens count "
    + "toward the conversation's usage."
  public static let unsetLabel = "Off"

  public init(visionModel: ModelRef?, choices: [ModelChoice]) {
    self.visionModel = visionModel
    self.choices = choices
  }

  public var choice: ModelRef? {
    get { visionModel }
    set { visionModel = newValue }
  }

  public var status: String {
    guard let visionModel else {
      return "Off. A bot whose model can't read images refuses them in its chat and gets only their names in "
        + "group chats."
    }
    guard let chosen = choices.first(where: { $0.ref == visionModel }) else {
      return "No provider key reaches \(visionModel.model), so images can't be read. Choose another model or "
        + "turn it off."
    }
    return "\(chosen.name) describes images for bots whose model can't read them."
  }
}
