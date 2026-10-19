# Changelog

## Unreleased

- Decode `toolName`, `isError`, and `toolDetails` on transcript messages, and add `DisplayComponent` for the visuals a bot shows with its `show` tool.
- Share `BotChatDelivery` and its behavior tests between the Apple clients. Keep transport tasks, connection guards, composer behavior, and native image conversion in each app.

- Send the device timezone with each chat message so bots know the owner's local time.
- Add `BotFinish` body finishes for bot avatars: glossy, matte, dither, halftone, grain, and outline, set with the `botFinish` environment value.
- Add the `BotAvatar` library with the shared bot avatar drawing, motion, and Core Animation live view for iOS and macOS.
- Extract common models, HTTP transport, event parsing, drafts, attachments, and pure helpers from the iOS and macOS clients.
- Connect both clients and their unit tests to `git@github.com:crumble-project/apfelkern.git`, tracking `main`.
- Preserve app-specific activity models, skill drafts, and invalid UTF-8 handling.
- Align iOS Debug builds with package dependencies by building only the selected simulator architecture.
