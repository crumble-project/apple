import Foundation
import Observation

/// The account's color theme, as the server names it.
public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, light, dark

  public var id: Self { self }

  public var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  public var symbol: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }
}

/// The theme this device shows. The device keeps it so it applies before the account loads and while
/// signed out; the account's theme replaces it once read, since another device may have changed it.
/// A choice shows at once and comes back on failure. Writes run one at a time and only the newest
/// choice waits, so the server ends on what the owner chose last.
@MainActor @Observable
public final class ThemeBoard {
  public private(set) var theme: AppTheme
  /// What a failed write comes back to.
  private var confirmed: AppTheme
  private var wanted: AppTheme?
  private(set) var isWriting = false
  private var order = ReadOrder()
  private var scope = 0
  @ObservationIgnored private let defaults: UserDefaults

  private static let storageKey = "theme"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.string(forKey: Self.storageKey).flatMap(AppTheme.init(rawValue:)) ?? .system
    theme = stored
    confirmed = stored
  }

  /// Keeps the theme on screen: a new connection takes its account's theme when that loads.
  public func reset() {
    scope += 1
    confirmed = theme
    wanted = nil
    isWriting = false
    order = ReadOrder()
  }

  /// A failed read keeps the theme on screen, as the web does: it only matters on another device.
  public func refresh(client: APIClient) {
    let version = scope
    let attempt = order.begin()
    Task {
      let account = try? await client.accountTheme()
      guard scope == version, order.accept(attempt), wanted == nil, let account else { return }
      confirmed = account
      show(account)
    }
  }

  /// Pass no client while signed out: the choice then stays on this device.
  public func choose(
    _ choice: AppTheme, client: APIClient?, session: URLSession = URLSession(configuration: .ephemeral),
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    guard choice != theme else { return }
    show(choice)
    guard let client else {
      confirmed = choice
      return
    }
    wanted = choice
    if !isWriting { write(choice, client: client, session: session, onFailure: onFailure) }
  }

  private func write(
    _ choice: AppTheme, client: APIClient, session: URLSession, onFailure: @escaping @MainActor (String) -> Void
  ) {
    isWriting = true
    let version = scope
    Task {
      var failure: String?
      do {
        try await client.setAccountTheme(choice, session: session)
      } catch {
        failure = friendlyError(error)
      }
      guard scope == version else { return }
      if failure == nil { confirmed = choice }
      order.settle()
      isWriting = false
      if let wanted, wanted != choice {
        write(wanted, client: client, session: session, onFailure: onFailure)
        return
      }
      wanted = nil
      if let failure {
        show(confirmed)
        onFailure(failure)
      }
    }
  }

  private func show(_ theme: AppTheme) {
    self.theme = theme
    defaults.set(theme.rawValue, forKey: Self.storageKey)
  }
}
