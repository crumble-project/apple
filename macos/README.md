# Crumble for macOS

Crumble for macOS is a native SwiftUI client for a running Crumble server. It provides agent management, one continuous chat per agent with streaming replies and file attachments, memory, schedules, integrations, and settings.

## Requirements

- macOS 26 or later.
- Xcode 26 or later, for Swift 6.2 and the macOS 26 SDK.
- A running Crumble server. Start the server from the sibling `bot` repository.

API dependencies are provided by the shared `apfelkern` package and pinned in `Package.resolved`.

## Shared Swift package

The app and unit tests fetch `https://github.com/crumble-project/apfelkern.git` at the exact reviewed commit in `Package.swift` and `Package.resolved`. A sibling checkout is not required.
The package provides generated API operations and event decoding, common domain models, API transport, drafts, and pure helpers. See the [package documentation](https://github.com/crumble-project/apfelkern).

Bot chat delivery uses `BotChatDelivery` from `apfelkern`. It coordinates pending messages, retry payloads, and previews. HTTP acceptance retains pending messages until a transcript snapshot confirms them. `AppModel` retains transport tasks, connection and selection guards, and composer behavior. Delivery behavior tests live in `apfelkern`; controlled transport tests remain in the app.

## Update the API client

Update the contract and generated client in apfelkern first. Update the exact package revision in `Package.swift`, resolve packages, and commit `Package.resolved` together. Run `swift test`. Do not add an app-local generator or duplicate wire models.

To verify unmerged shared changes locally, run `swift package edit apfelkern --path ../apfelkern`, then `swift test`. Run `swift package unedit apfelkern` before committing; local overrides must not enter the pin.

Apfelkern initially uses a checksum-verified local bot contract. Its pin must switch to `contract-v1.0.0` after bot's first release. Merge bot, then apfelkern, then this app, and refresh the app pin if apfelkern's merge changes the commit. Connection settings, cancellation, errors, optimistic delivery, and streaming lifetime remain app-owned.

PR CI runs unsigned `swift test` on a public GitHub-hosted macOS runner without signing credentials. The signed nightly workflow remains separate.

## Run the app

Run it straight from the package during development:

```bash
swift run Crumble
```

The app uses `http://127.0.0.1:7337` by default. Configure a different server without changing stored settings by setting these variables before starting the app:

```bash
CRUMBLE_URL="http://127.0.0.1:7338" CRUMBLE_TOKEN="REPLACE_WITH_A_SERVER_TOKEN" swift run Crumble
```

`CRUMBLE_TOKEN` must be treated as a secret. When you save connection settings, the app stores the server URL and token in the macOS Keychain under its bundle ID: `ng.crumbli.mac` for the installed app, and `ng.crumbli.mac.dev` for `swift run` and dev builds. Development never overwrites the installed app's connection.

## Tune bot avatars

Bot avatars live in the `BotAvatar` library from apfelkern, shared with the iOS app. The avatar playground shows a grid of random bots at every size, with state, live motion, a freeze-frame scrubber, and light and dark appearance controls:

```bash
swift run AvatarPlayground
```

Live avatars stretch, blink, and move at seed-specific rhythms. State changes blend poses and expressions, including closing eyes and fading sleep symbols. Hover over an awake idle avatar to catch its attention. Click a grid avatar to select it and trigger a greeting while awake. **Shuffle** fades between groups. Reduce Motion disables live movement and playground transitions.

Live avatars run their motion as Core Animation loops, so animating avatars use almost no CPU. Live avatars in Crumble use the same library, so they also get the movement and state transitions. Sidebar avatars keep working after you leave a running chat, then sleep when the server confirms completion.

Crumble paints bots with the `dither` finish. Use the playground's **Finish** picker to compare it with the other finishes: glossy, matte, halftone, grain, and outline. To write one row per finish as a PNG, run `swift run AvatarPlayground --finishes finishes.png`.

To write a still contact sheet of every state as a PNG instead, pass `--snapshot` with an output path and an optional moment in seconds:

```bash
swift run AvatarPlayground --snapshot avatars.png 0.3
```

## Verify the client

Install [SwiftLint](https://github.com/realm/SwiftLint) with Homebrew:

```bash
brew install swiftlint
```

Run lint checks from the repository root:

```bash
swiftlint lint
```

SwiftLint uses `.swiftlint.yml`, which excludes generated files in `.build` and `build`. Lint checks run separately from builds.

Run the tests:

```bash
swift test
```

Check the app bundle that notifications depend on, without launching it:

```bash
./scripts/check-app-bundle.sh
```

Build `build/Crumble.app`, with the icon from `resources/icon.png`:

```bash
./scripts/build-app.sh
```

The script signs the app ad hoc for local use. Set `CRUMBLE_SIGNING_IDENTITY` to a Developer ID Application identity to sign with the hardened runtime and a secure timestamp, which notarization requires. `CRUMBLE_VERSION` and `CRUMBLE_BUILD_NUMBER` set the version; both must be dot-separated numbers.

To install the app, copy `build/Crumble.app` to `/Applications`. For a development bundle that sits beside it with its own Keychain items, settings, and notifications, build `build/Crumble Dev.app`:

```bash
CRUMBLE_VARIANT=dev ./scripts/build-app.sh
```

## Nightly builds

[`.github/workflows/nightly.yml`](.github/workflows/nightly.yml) runs daily at 03:00 UTC when `main` has changed, and on demand from the Actions tab. It runs the tests, builds `Crumble.app`, signs it with Developer ID, notarizes and staples it, then replaces the `nightly` pre-release with `Crumble-nightly.zip`. The version is `0.1.0` with a `YYYYMMDD.run` build number.

The workflow reads these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of the Developer ID Application certificate and private key, exported as `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `NOTARY_KEY_P8` | Base64 of an App Store Connect Team API key (`.p8`) with the Developer role |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The App Store Connect issuer ID |

## Connect to a server

1. Start the server from the `bot` repository.
2. Copy the token from the server's `server-token` file.
3. Open Settings with **⌘,**.
4. Enter the server URL and token.
5. Click **Save Connection**.

The app sends the token as an `Authorization: Bearer` header. It does not send provider keys to the server during ordinary chat requests; provider credentials remain managed by the server.

## Chat

The main window contains searchable agent conversations. Click an agent's avatar or name in the conversation header to edit its profile.

Open **Settings** with **⌘,** or the sidebar's gear button. **General** contains connection, provider, and notification settings. The **Workspace** section contains **Memory**, **Skills**, **Tasks**, **Activity**, and **Integrations**. Workspace forms open in Settings without replacing your chat.

- Messages appear immediately with a sending indicator. Failed messages stay visible with **Retry**, which resends the original request without creating a duplicate.
- Return sends a message; Shift-Return or Option-Return starts a new line.
- The plus button beside the message field attaches files, and you can also drag files onto the field. A message can carry up to eight images (PNG, JPEG, GIF, WebP, up to 5 MB) or UTF-8 text files (up to 512 KB). The app converts other image formats, and larger images, to JPEG first.
- To ask another bot in a normal chat, write a request such as `Can you ask @Bot2 how he feels?` The responding bot can relay the answer when its profile has **Message other bots** enabled and **Bot2** selected in the permitted-bots list. Type `@` to complete permitted bot names. A faint inline suggestion appears after your text. Use the arrow keys to cycle matches, then press Tab or Return to insert the name as plain text. Press Escape to dismiss the suggestion. Mentions are sent as `@BotName` text.
- Bot-to-bot questions and answers are persisted as exchange cards in the chat. Each card identifies the sender and recipient and shows whether the exchange was sent, completed, failed, or cancelled; expand it to read the full question or answer.

## Tasks

Each task runs once, or on a cron schedule, in one bot's chat. Tasks are listed under the bot that runs them. Choose that bot in the task form; saving again can move the task to another bot. A bot can create and change tasks when **Schedule tasks** is on in its profile. It targets itself, or another bot it is allowed to message.

## Notifications

The app notifies you when a bot finishes a reply you aren't looking at, including replies to scheduled tasks. Click a notification to open the chat. macOS asks for permission on first launch. Notifications need the app bundle from `./scripts/build-app.sh`; `swift run` posts none. Notifications can be disabled in Settings.

Notifications are local: the app receives replies over its connection to your server, with no APNs or push service. They arrive while Crumble is running, including with its window closed, but not while it is quit, asleep, or offline. After reconnecting, chats and the bot list catch up from the server, without notifying for replies that were missed. See [Notifications on macOS](docs/notifications.md).

## Shared and personal items

**Memory**, **Skills**, and **Integrations** show **Shared** followed by a named section for every bot. All bots’ personal entries are visible together. Optional shared skills list the bots that use them.

- Add a memory from a bot’s section to assign it to that bot, or use **New Shared Memory**. A bot recalls shared memories only when **Use shared memory** is on in its profile.
- **Skills** includes bundled defaults and optional library skills together under **Shared**. Defaults are marked **Default · Every bot** and edited in the server's sibling `skills` directory; restart the server to load changes. Library skills are editable in the app and turned on per bot in its profile. Expand a skill to read its instructions. A bot's own skills are edited in its profile.
- Add an MCP server from a bot’s section to assign it to that bot, or use **Add Shared MCP Server**. A bot's own server has its own sign-in, so two bots can use the same service with different accounts. Tools from enabled, permitted integrations run directly without per-action confirmation.

## Integrations

Add MCP servers under **Integrations**. For a server that uses a token, enter it in the server's form. For a server that uses OAuth, leave the token empty, save, and choose **Sign In…** in the list; the app shows the provider's sign-in page, and the Crumble server keeps the tokens.

## Current scope and limitations

The server remains the source of truth for persistent state. The product is still under active development. Hermes Agent and Grok Bot parity is a target for end-to-end acceptance, not a statement that every capability is complete. Review the server's [`docs/product-parity.md`](../bot/docs/product-parity.md) and [`docs/architecture.md`](../bot/docs/architecture.md) before planning a release.

Known limitations include:

- A live server with valid provider credentials is required for model responses.
- macOS signing and notarization are not configured by this repository.
- The app targets macOS; other operating systems are outside the product scope.
