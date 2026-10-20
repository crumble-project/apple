# apfelkern

Shared Swift code for the Crumble iOS and macOS clients. Requires Swift 6.2 or later and iOS 26 or macOS 26.

## Package contents

- API request encoding, response decoding, bearer authentication, and server-sent event parsing.
- Common server models, JSON values, and bot chat delivery state, including optimistic messages, retries, and transcript acknowledgement.
- Agent, memory, task, and integration drafts.
- Transcript merging, mention completion, message previews, OAuth callbacks, task validation, and date formatting.
- Attachment metadata, encoding, and limits, plus avatar seed selection.

The `apfelkern` library uses Foundation, Apple's Swift OpenAPI Runtime, and HTTPTypes. It contains no SwiftUI, UIKit, or AppKit code.

The separate `BotAvatar` library draws the bot avatars with SwiftUI. Live avatars run their motion as looping Core Animation keyframes, hosted in an AppKit or UIKit view, so they cost the app almost no CPU while they animate. Import it with `import BotAvatar`. Choose a body finish with `.environment(\.botFinish, .dither)`: `glossy` (the default), `matte`, `dither`, `halftone`, `grain`, or `outline`. The avatar drawing is adapted from MIT-licensed work; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The Android client ports the same drawing and motion with the `dither` finish in `android/app/src/main/java/dev/crumble/android/ui/BotAvatar.kt`, so carry avatar changes over to keep a seed's bot the same on every platform.

## Use the package

Both clients consume a reviewed apfelkern revision. Public consumers can resolve `https://github.com/crumble-project/apfelkern.git` without private package access.
A sibling checkout is not required. Import the public API with `import apfelkern`.

Commit and push package changes before updating either client's resolved revision. Uncommitted local changes are not included in remote dependencies.

`BotChatDelivery` owns pending messages, retry payloads, and previews for both clients. HTTP acceptance retains pending messages until a transcript snapshot confirms them. The apps retain UI, observable application state, network tasks, connection and selection guards, composer restoration, notifications, Keychain storage, and image conversion.
Activity and push operations share public adapters: `ActivityEvent`, `ActivityEntry`, `ActivityFeedResponse`, `PushDevice`, `PushStatus`, and `PushRegistration`. Activity details remain open JSON. Skill drafts retain their platform-specific fields.
The transport preserves each platform's existing handling of invalid UTF-8.

## Generate the API client

Bot owns the HTTP contract and event schemas. `Contract/pin.json` identifies the exact version, source commit, provenance, and payload checksums.
The initial pin is explicitly a **local export**, not a published release. After bot publishes `contract-v1.0.0`, update the pin before merging this integration.
Ordinary builds use committed output and never fetch contracts or invoke a generator.

`Generation/tools.json` records Swift OpenAPI Generator `1.14.2`, Runtime `1.13.2`, HTTPTypes `1.7.0`, and repository URLSession transport `1.0.0`.
Apple's URLSession transport `1.3.2` was evaluated but cannot set each request's timeout while retaining the injected session.
The repository transport preserves 20-second requests, 60-second OAuth, 120-second attachment uploads, 24-hour SSE requests, cancellation, and 8 KiB error bodies.
Its versioned source is `Sources/apfelkern/ContractTransport.swift`; it adds no networking dependency.

Regenerate committed types and client operations:

```sh
python3 scripts/contract.py
```

The command clones the exact generator tag, checks its commit and unmodified tracked sources, then builds its CLI in `.build`.
`Generation/generator-Package.resolved` pins the CLI's parser and other transitive dependencies. Generation uses `--force-resolved-versions` and never silently re-resolves them.
The first run needs public GitHub access and Swift 6.2 or later. Subsequent ordinary package builds need no generator.
Generated `Client`, `Operations`, and `Components.Schemas` remain public. Do not edit `Sources/apfelkern/Generated`.
`APIClient` calls typed generated operations for every endpoint, including attachments and SSE. Its generic `send` and `call` remain escape hatches only.
Presentation models preserve editable defaults, optimistic delivery state, identities, and integer timestamps through explicit adapters. They aren't HTTP wire decoders.
`OutgoingAttachment`, `CodingJobsResponse`, and `PushRegistration` directly alias generated types.

The deterministic projection adds downloaded event schemas as OpenAPI components. It translates JSON Schema `const` to equivalent single-value `enum`.
Generator `1.14.2` omits responses containing `anyOf` of a reference and `null`. The projection expands only that exact nullable-object pattern to an equivalent nullable inline object.
Unexpected nullable union shapes fail rather than silently changing their meaning. Pinned assets remain unchanged.
Generated optional properties also omit explicit JSON nulls when encoding. The transport restores only operation-allowlisted null fields from the caller's intent.
Schedule date-time requests accept RFC 3339 timestamps with or without fractional seconds and preserve millisecond precision.
SSE framing skips unknown event names, unknown activity types, and heartbeats. Accepted payloads decode through generated event types; malformed known events fail.
Sparse payloads that omit contract-required fields are no longer accepted. Domain initializers still support optimistic presentation state.

Check reproducibility without changing committed output:

```sh
python3 scripts/contract.py --check
```

The check verifies every payload checksum and the pin, regenerates in a temporary directory, and compares every generated file byte-for-byte.
It rejects stale output, extra generated files, and manual edits. SwiftLint excludes generated files; reproduction checks protect them instead.

## Update the contract

To adopt a published immutable contract release, replace `contract-v1.0.0` with the selected tag:

```sh
python3 scripts/contract.py --update contract-v1.0.0
```

Before the first release, export a bundle in bot with `bun src/openapi.ts --bundle DIRECTORY`.
Replace `DIRECTORY` with an absolute output path, then pass that path to the updater:

```sh
python3 scripts/contract.py --update DIRECTORY
```

Both update modes require all seven release assets. Checksums cover OpenAPI, all three event schemas, the changelog, and source provenance.
The updater verifies every checksum before copying assets or generating code, records release or local provenance, regenerates, and runs `swift test`.
Review the contract changelog, pin, generated diff, and app integration checks together. Commit the pin and generated output together.

Public CI checks reproduction, builds, tests, lints, and builds `BotAvatar` for iOS Simulator without signing or deployment credentials.
The weekly updater selects the most recently published stable `contract-vX.Y.Z` release, independently of server releases.
It runs all checks itself before creating or updating a PR with `GITHUB_TOKEN`. GitHub can require approval for token-created PR workflow runs.
No release is a reported bootstrap skip; download, authentication, checksum, or parsing failures fail the workflow.
Repository policy must permit GitHub Actions to create PRs. An owner must enable that policy if disabled; these scripts don't change it.

Sources: [Apple CLI documentation](https://github.com/apple/swift-openapi-generator/blob/1.14.2/Sources/swift-openapi-generator/Documentation.docc/Articles/Manually-invoking-the-generator-CLI.md), [Apple transport API](https://github.com/apple/swift-openapi-urlsession/blob/1.3.2/Sources/OpenAPIURLSession/URLSessionTransport.swift), [GitHub workflow triggers](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow), and [GitHub releases API](https://docs.github.com/en/rest/releases/releases).

## Verify changes

Run package checks:

```sh
python3 scripts/contract.py --check
swift build
swift test
swiftlint lint
```

Build `BotAvatar` for iOS as well, because its live view has separate AppKit and UIKit code:

```sh
xcodebuild -scheme BotAvatar -destination 'generic/platform=iOS Simulator' build
```

The `apfelkernTests` target covers bot chat delivery transitions; `BotAvatarTests` covers avatar motion. Client suites retain controlled transport tests for acknowledgement ordering, late failures, and connection or bot changes.
Run `swift test` in `../desktop` and the unit tests in the `../ios` Xcode project after changing shared behavior.
The iOS test script also runs UI tests; see the [iOS build and test instructions](../ios/README.md#build-and-test).
