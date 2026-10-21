import Foundation

/// Scopes Keychain items and the sign-in callback, so the installed app and dev builds never share them.
/// `swift run` has no bundle, so it uses the dev identity.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "ng.crumbli.mac.dev"
}
