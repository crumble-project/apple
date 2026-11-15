import apfelkern
import BotAvatar
import SwiftUI

/// A bot's avatar that comes alive without a jump. A still avatar and a live one rest in slightly
/// different poses, so switching between them snaps; this fades the live one in over the still
/// one, and when it ends, lets the gaze drift home before fading back. Avatars draw on the CPU
/// every frame, so the live layer exists only while it is needed.
struct CalmAvatar: View {
    let agent: Agent
    let size: CGFloat
    let state: BotState
    /// Follows the pointer; a working bot animates either way.
    var active = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawing = false
    @State private var shown = false
    /// The still avatar stays opaque under every fade: two half-transparent copies of the same
    /// avatar let the background through and wash it out. It hides only once the live one is solid.
    @State private var covered = false

    private var animating: Bool { active || state == .working }
    private var fadeIn: Duration { .milliseconds(reduceMotion ? 0 : 250) }
    private var fadeOut: Duration { .milliseconds(reduceMotion ? 0 : 300) }

    var body: some View {
        ZStack {
            BotAvatarView(agent: agent, size: size, state: state)
                .opacity(covered ? 0 : 1)
            if drawing {
                BotAvatarView(agent: agent, size: size, state: state, live: true, followsPointer: active)
                    .opacity(shown ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .task(id: animating) { await settle(animating) }
    }

    private func settle(_ animate: Bool) async {
        if animate {
            drawing = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { shown = true }
            try? await Task.sleep(for: fadeIn)
            guard !Task.isCancelled else { return }
            covered = true
            return
        }
        guard drawing else { return }
        // Long enough for the gaze to drift back to the middle once it stops following.
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 700))
        guard !Task.isCancelled else { return }
        covered = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { shown = false }
        try? await Task.sleep(for: fadeOut)
        guard !Task.isCancelled else { return }
        drawing = false
    }
}
