# Changelog

## Unreleased

- Pin bot contract `1.0.0` as a checksum-verified local export from source commit `40d7b6a`; adopt the published release before merging the integration.
- Generate and commit public Swift HTTP operations and event payload models with Apple Swift OpenAPI Generator `1.14.2` and Runtime `1.13.2`, without build plugins. Pin the CLI's complete dependency resolution and fail rather than silently updating its parser dependencies.
- Route every `APIClient` endpoint through typed generated operations, including attachment bytes and SSE. Preserve the injected URLSession, bearer authentication, request timeouts, cancellation, bounded errors, explicit nullable requests, and domain initializers.
- Share activity and push facades across Apple apps. Decode known SSE payloads through generated schemas while ignoring heartbeat and unknown event frames. Contract-required fields are now enforced at the wire boundary.
- Add deterministic regeneration checks, checksum-verified local or release updates, public CI, and a weekly contract updater that validates changes before opening a PR with `GITHUB_TOKEN`.

- Remove `folder` from `Agent` and `AgentDraft`. The server no longer has the field.
- Add `Reaction`, which reads the emoji from a bot's `react` tool result and groups reactions by the message they answer.
- Decode `toolName`, `isError`, and `toolDetails` on transcript messages, and add `DisplayComponent` for the visuals a bot shows with its `show` tool. Charts decode as `ChartLayout` drawing primitives with theme tokens; `ChartPalette` holds the light and dark series colors.
- Share `BotChatDelivery` and its behavior tests between the Apple clients. Keep transport tasks, connection guards, composer behavior, and native image conversion in each app.

- Send the device timezone with each chat message so bots know the owner's local time.
- Add `BotFinish` body finishes for bot avatars: glossy, matte, dither, halftone, grain, and outline, set with the `botFinish` environment value.
- Add the `BotAvatar` library with the shared bot avatar drawing, motion, and Core Animation live view for iOS and macOS.
- Extract common models, HTTP transport, event parsing, drafts, attachments, and pure helpers from the iOS and macOS clients.
- Connect both clients and their unit tests to `git@github.com:crumble-project/apfelkern.git`, tracking `main`.
- Preserve app-specific activity models, skill drafts, and invalid UTF-8 handling.
- Align iOS Debug builds with package dependencies by building only the selected simulator architecture.
