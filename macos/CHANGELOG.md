# Changelog

## Unreleased

- Restyle the app after the GPUI client with native components: the system split view with a searchable sidebar list, toolbar buttons for a new agent and the details inspector, and a centered transcript column under a dithered arch in the bot's color. Bot bubbles are gray and owner bubbles use the accent color, with reply and copy on hover and reactions in glass badges at the message corner; the glass composer has a send button. The inspector shows the live avatar, routines with switches that pause and resume them, memories, and the model, and opens the profile editor.
- Show a bot's emoji reaction under the message it answers, instead of an empty reply.
- Render visuals a bot shows with its `show` tool inline in chat: headline numbers, tables, and compiled charts drawn natively with hover tooltips, in light and dark appearance. Render Markdown tables in replies.
- Use apfelkern's shared bot chat delivery module, preserving optimistic sends, retries, and transcript confirmation. Keep transport timing tests in the app.

- Paint bots with a dithered finish instead of a glossy one. The playground's **Finish** picker and `--finishes` sheet compare all finishes.
- Tone down avatar blush, eye sparkle, and smiles. Use smaller working hops and restrained click greetings while retaining live motion and state transitions.

- Blend live avatar poses and expressions across idle, working, and sleeping states. Add occasional stretches, individual movement rhythms, fading sleep symbols, click greetings in the playground, and shuffle transitions. Respect Reduce Motion.

- Open Settings (⌘, or the sidebar's gear) in a regular resizable window, so its toolbar shares the title row instead of leaving an empty band above the content, with a bounded General form. Position the chat profile header near the window's top edge.

- Move bot avatars into apfelkern's `BotAvatar` library, shared with the iOS app.
- Play live avatars with Core Animation: each part is drawn once and each state loops as keyframes in the render server, so animating avatars use almost no app CPU (24 live avatars went from about 17% to under 0.3%).
- Give bot avatars shaded bodies, catchlit eyes, mouths, cheeks, and a seeded topper. Live avatars breathe, glance around, double-blink, and watch the pointer, and toppers bounce while working.
- Bots with confirmed running work stay in the working state after you leave their chat. Background chat streams track completion without replacing the selected chat. Other bots sleep unless their chat is open. All sidebar avatars animate unless Reduce Motion is enabled.
- Add `swift run AvatarPlayground` for tuning avatars. Run the app with `swift run Crumble`.
- Use a Messages-style conversation sidebar with search, a centered agent profile header, and a compact composer.
- Move Memory, Skills, Tasks, Activity, and Integrations into Settings, with workspace forms presented in that window.
- Keep workspace navigation separate from the active conversation.
