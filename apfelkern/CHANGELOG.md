# Changelog

## Unreleased

- Add the `BotAvatar` library with the shared bot avatar drawing, motion, and Core Animation live view for iOS and macOS.
- Extract common models, HTTP transport, event parsing, drafts, attachments, and pure helpers from the iOS and macOS clients.
- Connect both clients and their unit tests to `git@github.com:crumble-project/apfelkern.git`, tracking `main`.
- Preserve app-specific activity models, skill drafts, and invalid UTF-8 handling.
- Align iOS Debug builds with package dependencies by building only the selected simulator architecture.
