# Crumble for macOS

Crumble for macOS is a native SwiftUI client for a running Crumble server. It provides agent management, one continuous chat per agent with streaming replies and file attachments, memory, schedules, integrations, approvals, and settings.

## Requirements

- macOS 26 or later.
- Xcode 26 or later, for Swift 6.2 and the macOS 26 SDK.
- A running Crumble server. Start the server from the sibling `bot` repository.

The app has no third-party dependencies.

## Run the app

Run it straight from the package during development:

```bash
swift run
```

The app uses `http://127.0.0.1:7337` by default. Configure a different server without changing stored settings by setting these variables before starting the app:

```bash
CRUMBLE_URL="http://127.0.0.1:7338" CRUMBLE_TOKEN="REPLACE_WITH_A_SERVER_TOKEN" swift run
```

`CRUMBLE_TOKEN` must be treated as a secret. When you save connection settings, the app stores the server URL and token in the macOS Keychain under the `dev.crumble.desktop` service.

## Verify the client

Run the tests:

```bash
swift test
```

Build `build/Crumble.app`, with the icon from `resources/icon.png`:

```bash
./scripts/build-app.sh
```

The script signs the app ad hoc for local use. It is not notarized. Distribution requires a Developer ID signing identity and a separate notarization workflow.

## Connect to a server

1. Start the server from the `bot` repository.
2. Copy the token from the server's `server-token` file.
3. Open Settings with **⌘,**.
4. Enter the server URL and token.
5. Click **Save Connection**.

The app sends the token as an `Authorization: Bearer` header. It does not send provider keys to the server during ordinary chat requests; provider credentials remain managed by the server.

## Chat

- Return sends a message; Shift-Return or Option-Return starts a new line.
- The plus button beside the message field attaches files, and you can also drag files onto the field. A message can carry up to eight images (PNG, JPEG, GIF, WebP, up to 5 MB) or UTF-8 text files (up to 512 KB). The app converts other image formats, and larger images, to JPEG first.
- To ask another bot in a normal chat, write a request such as `Can you ask @Bot2 how he feels?` The responding bot can relay the answer when its profile has **Message other bots** enabled and **Bot2** selected in the permitted-bots list. Mentions are plain text; the client does not promise autocomplete.
- Bot-to-bot questions and answers are persisted as exchange cards in the chat. Each card identifies the sender and recipient and shows whether the exchange was sent, completed, failed, or cancelled; expand it to read the full question or answer.

## Notifications

The app notifies you when a bot finishes a reply you aren't looking at, including replies to scheduled tasks, and when a tool call waits for your approval. Click a notification to open the chat or Approvals. macOS asks for permission on first launch. Notifications need the app bundle from `./scripts/build-app.sh`; `swift run` posts none.

## Shared and personal items

**Memory**, **Skills**, and **Integrations** show **Shared** followed by a named section for every bot. All bots’ personal entries are visible together. Optional shared skills list the bots that use them.

- Add a memory from a bot’s section to assign it to that bot, or use **New Shared Memory**. A bot recalls shared memories only when **Use shared memory** is on in its profile.
- **Skills** includes bundled defaults and optional library skills together under **Shared**. Defaults are marked **Default · Every bot** and edited in the server's sibling `skills` directory; restart the server to load changes. Library skills are editable in the app and turned on per bot in its profile. Expand a skill to read its instructions. A bot's own skills are edited in its profile.
- Add an MCP server from a bot’s section to assign it to that bot, or use **Add Shared MCP Server**. A bot's own server has its own sign-in, so two bots can use the same service with different accounts.

## Integrations

Add MCP servers under **Integrations**. For a server that uses a token, enter it in the server's form. For a server that uses OAuth, leave the token empty, save, and choose **Sign In…** in the list; the app shows the provider's sign-in page, and the Crumble server keeps the tokens.

## Current scope and limitations

The server remains the source of truth for persistent state. The product is still under active development. Hermes Agent and Grok Bot parity is a target for end-to-end acceptance, not a statement that every capability is complete. Review the server's [`docs/product-parity.md`](../bot/docs/product-parity.md) and [`docs/architecture.md`](../bot/docs/architecture.md) before planning a release.

Known limitations include:

- A live server with valid provider credentials is required for model responses.
- macOS signing and notarization are not configured by this repository.
- The app targets macOS; other operating systems are outside the product scope.
