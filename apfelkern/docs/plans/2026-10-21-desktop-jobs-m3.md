# Desktop jobs, milestone 3 (apfelkern): client support — Implementation Plan

> Implement one task at a time. Review each deliverable before starting the next. Steps use `- [ ]`.

**Goal:** apfelkern gives the iOS and macOS clients everything they need for desktop jobs from bot contract 1.6.0: the `desktop` capability, a bot's desktop job model (including clearing it), desktop jobs with their usage, the control lease with its live events, and single-use viewer links.
**Architecture:** Everything goes through the generated client (`Sources/apfelkern/Generated`, pinned to `contract-v1.6.0` in the previous commit). Desktop jobs mirror `CodingJob`. Control events are a new SSE stream like `chatEvents`, validated with the generated `EventDesktopControl`. A viewer link is the server's relative path resolved against `APIClient.baseURL`; it needs no token. See [feature 0002](https://github.com/crumble-project/spec/blob/main/features/0002-desktop-jobs.md) and bot's `docs/architecture.md` ("Desktop jobs").
**Tech stack:** Swift 6.2, swift-openapi-generator 1.14.2, Swift Testing.

## Global constraints

- Branch `feat/0002-desktop-jobs`; commit after each task with Conventional Commits.
- Glossary: bot desktop, desktop job, taking control.
- No hand edits in `Sources/apfelkern/Generated/`.
- Clients may talk to servers from contract 1.6.0 on; the pinned client requires it.
- Done means `python3 scripts/contract.py --check`, `swift build`, `swift test`, and `swiftlint lint` pass, plus `swift test` in `../desktop` with `APFELKERN_LOCAL=1`.

## Task 1: Desktop capability and desktop model

- `ServerCapabilities.desktop: Bool`, decoded leniently like `coding`; `APIClient.capabilities()` maps the generated field.
- `Agent.desktopModel: DesktopModel?` with `DesktopModel { provider: String; model: String }`, read and written through the agent wire adapters.
- `AgentDraft.toolsDesktop` and `AgentDraft.desktopModel`, mapped like `toolsCoding`.
- `updateAgent(_:patch:)` passes the patch's `null` keys as `nullFields`, and `restoreNullFields` allows `desktopModel` for `UpdateAgent`, so `["desktopModel": .null]` clears the override.
- Tests: capabilities decode `desktop`; an agent with `desktopModel` round-trips; a patch with `desktopModel: null` sends a JSON `null` (inspect the request body in `ContractURLProtocol`).

## Task 2: Desktop jobs and job usage

- `DesktopJob` mirrors `CodingJob` (`toolName = "desktop"`, `originKind = "desktop"`, `init?(message:)`), plus `usage: JobUsage?`.
- `JobUsage { inputTokens, outputTokens, cachedTokens: Int; cost: Double }`, summed over the job's models from the generated `usage` document; `CodingJob` gets `usage` too.
- `APIClient.desktopJobs(_:)` and `desktopJobHistory(_:name:before:limit:)`, like the coding job pair.
- `messageLabel` returns "Desktop job · name" for origin `desktop`.
- Tests: listing decodes usage and sums two models; a `desktop` tool result parses as `DesktopJob`; the label.

## Task 3: Control, control events, and viewer links

- `DesktopControl { holder: Holder (.bot, .owner); changes: Int; updatedAt: String }`.
- `APIClient.desktopControl(_:)`, `setDesktopControl(_:holder:)`.
- `APIClient.desktopEvents(_:onEvent:)`: the `control` SSE stream. Add `Operations.StreamDesktopEvents.id` to `ContractTransport.streamingOperations`, and `SSEParser` gains a `.desktopControl` mode that accepts `control` events validated as `EventDesktopControl`.
- `APIClient.desktopViewerURL(_:) -> DesktopViewerLink { url: URL; expiresAt: String }`, resolving the returned path against `baseURL` including its path prefix, as API requests do, so a server behind a reverse proxy under a prefix works.
- Tests: set and get control; a stream delivers `control` events and skips heartbeats; a viewer link resolves to `https://host/prefix/desktop-viewer/<ticket>` for the base URL `https://host/prefix/`.

## Task 4: Docs

- `CHANGELOG.md` Unreleased entries naming the new types and `APIClient` operations.
- README: nothing beyond the changelog unless it lists operations.
