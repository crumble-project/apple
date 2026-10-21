# Desktop jobs, milestone 3 (macOS): desktop jobs, the bot desktop view, and notifications — Implementation Plan

> Implement one task at a time. Review each deliverable before starting the next. Steps use `- [ ]`.

**Goal:** The owner can give a bot a bot desktop and a desktop job model in the bot editor, follow desktop jobs as cards in the chat like coding jobs, watch the bot desktop in its own window, take control and hand it back, and open that window from a notification when a desktop job answers.
**Architecture:** Coding job state, cards, and the job sheet become kind-aware (`JobKind`: coding, desktop) instead of being copied. The bot desktop window is a `WindowGroup` keyed by the bot's ID: a `WKWebView` loads the server's single-use viewer link (noVNC is served by the server, not bundled), with SwiftUI controls around it. A `BotDesktopSession` (`@Observable`, unit-tested) owns the link, the control state from `desktopEvents`, and pending take/hand-back requests, which show as pending until the server confirms (AGENTS.md: outcomes that depend on another system). See [feature 0002](https://github.com/crumble-project/spec/blob/main/features/0002-desktop-jobs.md) and apfelkern's desktop job support.
**Tech stack:** Swift 6.2, SwiftUI, WebKit, apfelkern (pinned), Swift Testing.

## Global constraints

- Branch `feat/0002-desktop-jobs`; commit after each task.
- Glossary: bot desktop, desktop job, taking control. UI copy: "Bot Desktop", "Take Control", "Hand Back".
- Optimistic UI rules (AGENTS.md): taking and handing back control show a pending state and change only when the server confirms; a failure leaves the previous holder and shows an error.
- No UI tests and nothing needing a simulator in CI; logic lives in models that `swift test` covers.
- Done means `swift test` passes, `scripts/build-app.sh` builds, and a manual run against a server with both workspace images works.

## Task 1: Kind-aware jobs

- `JobKind` (`coding`, `desktop`) with its icon (`hammer.fill`, `display`), label, and client calls.
- `CodingJobHistory` becomes `JobHistory` with a `kind`; `AppModel.codingJobHistory` becomes `jobHistory`. `AppModel.desktopJobs` sits next to `codingJobs`, refreshed on desktop job activity the same way.
- `CodingJobCard` becomes `JobCard(kind:job:)`. `ChatMessages` renders a `DesktopJob` tool result as a desktop job card, and `ChatView` hides desktop job reports from the visible rows as it hides coding ones.
- `JobSheet` shows either kind, with the job's usage (tokens and cost) under its title. A desktop job's sheet has "Open Bot Desktop".
- Tests: desktop jobs refresh after desktop job activity; opening a desktop job loads `desktop-jobs/{name}/history`; a coding job still loads `coding-jobs/…`; usage formats as "1,000 in · 500 out · $0.0020".

## Task 2: Desktop in the bot editor

- A "Bot desktop" toggle under Capabilities when `capabilities.desktop` or the bot already has it, with a footer explaining desktop jobs.
- When on: "Desktop job model": a provider picker and model field like the bot's own, empty meaning "Same as the bot".
- `openEditor` reads `tools` and `desktopModel`; `editorInput` writes `desktop` and the model; `editorPatch` sends `desktopModel` as an object, or `null` when both fields are empty.
- Tests: the toggle follows capabilities; a draft with a model patches `{"provider","model"}`; clearing sends `null`.

## Task 3: The bot desktop window

- `BotDesktopSession(agentID:)`:
  - `connect()` fetches a viewer link and starts `desktopEvents`.
  - `holder`, `changes`, and `pending: Holder?`.
  - `take()` and `handBack()` set `pending`, call `setDesktopControl`, and apply the confirmed state, or restore and show the error.
  - `reconnect()` fetches a new link, since links are single-use.
- `BotDesktopView`: a `WKWebView` (`NSViewRepresentable`) on the link, with a toolbar showing who has control, Take Control or Hand Back (a spinner while pending), and Reconnect.
- `WindowGroup("Bot Desktop", id: "bot-desktop", for: String.self)`, opened from:
  - a "Bot Desktop" toolbar button in a bot chat whose bot has the `desktop` tool,
  - a desktop job card or sheet.
- Closing the window while holding control hands control back. An unwatched pause would block the bot's job with nobody to notice, and SwiftUI has no close confirmation without an AppKit window delegate.
- Tests:
  - Taking control stays pending until the server answers, then shows the owner.
  - A failed take restores the bot and shows the error.
  - A control event from another client updates the holder.
  - Reconnect asks for a new link.

## Task 4: Notifications from desktop jobs

- `notification(for:in:)`: a `reply` with origin `desktop` is titled "Desk · desktop job github" (falling back to "desktop job" without a name). Origin `coding` similarly says "coding job".
- `NotificationTarget` gains `desktop: Bool` from origin `desktop`, carried in `userInfo`.
- A click on a desktop notification opens the bot's chat and its bot desktop window (`Notifier.openBotDesktop`, set by the main scene like `openMainWindow`).
- Tests: titles for both job origins; the target round-trips through `userInfo`; routing a desktop target opens the chat and calls `openBotDesktop`.
- `docs/notifications.md` describes job answers.

## Task 5: Docs and manual check

- `CHANGELOG.md` Unreleased entries.
- Run the app against a server with both images, then:
  1. Turn on Bot desktop for a bot and pick a desktop model.
  2. Ask it for a task and watch the card and the job sheet.
  3. Open the bot desktop, take control, type, and hand back.
  4. Let a job ask for a login and click its notification.
