import apfelkern
import Foundation

extension AppModel {
  var gitHubWebSignInURL: URL? { client?.webSignInURL }
  var gitHubCallbackURL: String? { client?.gitHubAppCallbackURL }

  func loadGitHubApps() {
    guard let client else { return }
    gitHubAppBoard.refresh(client: client)
  }

  func editGitHubApp(_ app: GitHubApp) {
    guard let client else { return }
    gitHubAppBoard.edit(app, client: client)
  }

  func saveGitHubAppDraft() {
    guard let client else { return }
    gitHubAppBoard.saveDraft(client: client)
  }

  func saveGitHubAppClientSecret() {
    guard let client else { return }
    gitHubAppBoard.saveClientSecret(client: client)
  }

  func removeGitHubApp(_ app: GitHubApp) {
    guard let client else { return }
    gitHubAppBoard.remove(app, client: client)
  }

  func connectGitHubApp(_ app: GitHubApp) {
    guard let client else { return }
    gitHubAppBoard.connect(app, client: client)
  }

  func signOutOfGitHubApp(_ app: GitHubApp) {
    guard let client else { return }
    gitHubAppBoard.signOut(app, client: client)
  }

  func createGitHubApp() {
    guard let client else { return }
    gitHubAppBoard.createOnGitHub(client: client)
  }

  func installGitHubApp(_ app: GitHubApp) {
    guard let client else { return }
    gitHubAppBoard.install(app, client: client)
  }

  func signInToGitHubApp(_ app: GitHubApp) {
    guard let client else { return }
    gitHubAppBoard.signIn(app, client: client)
  }

  func stopWaitingForGitHub() {
    guard let client else { return }
    gitHubAppBoard.stopWaiting(client: client)
  }

  func gitHubBrowserClosed(_ trip: GitHubTrip) {
    guard let client else { return }
    gitHubAppBoard.browserClosed(trip, client: client)
  }
}
