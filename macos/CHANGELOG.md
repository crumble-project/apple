# Changelog

## Unreleased

- Use apfelkern's shared bot chat delivery module, preserving optimistic sends, retries, and transcript confirmation. Keep transport timing tests in the app.

- Paint bots with a dithered finish instead of a glossy one. The playground's **Finish** picker and `--finishes` sheet compare all finishes.
- Tone down avatar blush, eye sparkle, and smiles. Use smaller working hops and restrained click greetings while retaining live motion and state transitions.

- Blend live avatar poses and expressions across idle, working, and sleeping states. Add occasional stretches, individual movement rhythms, fading sleep symbols, click greetings in the playground, and shuffle transitions. Respect Reduce Motion.

- Use a compact Settings toolbar and a resizable window with a bounded General form. Position the chat profile header near the window's top edge.

- Move bot avatars into apfelkern's `BotAvatar` library, shared with the iOS app.
- Play live avatars with Core Animation: each part is drawn once and each state loops as keyframes in the render server, so animating avatars use almost no app CPU (24 live avatars went from about 17% to under 0.3%).
- Give bot avatars shaded bodies, catchlit eyes, mouths, cheeks, and a seeded topper. Live avatars breathe, glance around, double-blink, and watch the pointer, and toppers bounce while working.
- Bots with confirmed running work stay in the working state after you leave their chat. Background chat streams track completion without replacing the selected chat. Other bots sleep unless their chat is open. All sidebar avatars animate unless Reduce Motion is enabled.
- Add `swift run AvatarPlayground` for tuning avatars. Run the app with `swift run Crumble`.
- Use a Messages-style conversation sidebar with search, a centered agent profile header, and a compact composer.
- Move Memory, Skills, Tasks, Activity, and Integrations into Settings, with workspace forms presented in that window.
- Keep workspace navigation separate from the active conversation.
