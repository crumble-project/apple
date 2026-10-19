import Foundation

/// Scopes Keychain items, the sign-in callback, and push topics, so Debug and Release installs never share them.
enum AppIdentity {
  static let bundleID = Bundle.main.bundleIdentifier ?? "ng.crumbli.ios.dev"
}
