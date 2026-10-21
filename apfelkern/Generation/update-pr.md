## Summary

Update the bot contract pin and regenerate the Swift client with the recorded tool versions.

## Evidence

The updater verifies every payload checksum before generation. Before creating this PR, it runs byte-for-byte regeneration checks, `swift build`, `swift test`, `swiftlint lint`, and the unsigned iOS Simulator build of `BotAvatar`.

Review the workflow run and the contract changelog in `Contract/CHANGELOG.md` before merging. Public PR checks might require approval for a PR created with `GITHUB_TOKEN`; this updater runs its own checks regardless.

## Risk & Rollback

**Reversibility:** Reversible. Revert the pin and generated output together.

**Blast Radius:** Shared HTTP operations and event payloads consumed by the Apple apps. Both apps build against this apfelkern by path, so run the macOS tests and the iOS build and unit tests before merging.
