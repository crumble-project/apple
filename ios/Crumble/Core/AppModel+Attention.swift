import apfelkern
import UIKit

extension AppModel {
  /// Reports the chat the scene shows while it's active and the account signed in.
  func updateChatAttention() {
    chatAttention.update(client: isSignedIn ? client : nil, active: attentionActive, route: route?.attentionChat)
  }

  /// Only an active scene has attention. Leaving it gets a short grace, so the clear can land before iOS suspends
  /// the app; a clear that doesn't expires on the server.
  func setSceneActive(_ active: Bool) {
    guard active != attentionActive else { return }
    attentionActive = active
    guard !active, attentionGrace == .invalid else { return }
    attentionGrace = UIApplication.shared.beginBackgroundTask(withName: "Clear chat attention") { [weak self] in
      Task { @MainActor in self?.endAttentionGrace() }
    }
    Task {
      await chatAttention.settle()
      endAttentionGrace()
    }
  }

  private func endAttentionGrace() {
    guard attentionGrace != .invalid else { return }
    UIApplication.shared.endBackgroundTask(attentionGrace)
    attentionGrace = .invalid
  }
}
