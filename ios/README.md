# Crumble for iOS

Crumble is a native SwiftUI client for your Crumble server, built for iPhone and iPad.
It uses the same authenticated API as the macOS and Android apps, with no third-party dependencies.

## Requirements

- iOS or iPadOS 26 or later.
- Xcode 26 or later with the iOS SDK.
- A running Crumble server from the sibling `bot` directory.
- An Apple signing team to install on a physical device.

## Open the project

Open `Crumble.xcodeproj` in Xcode and select the **Crumble** scheme.
Select an iPhone or iPad simulator, then run the app.
For a physical device, select your team under **Signing & Capabilities** before running.
The bundle identifier is `dev.crumble.ios`; change it if your signing account requires a unique identifier.

## Connect to your server

1. Open **Settings** from the app's navigation list.
2. Enter your server URL.
3. Enter the token from the server's `server-token` file.
4. Tap **Save Connection**.
5. Tap **Done** after the connection succeeds.

The simulator can reach a server on your Mac at `http://127.0.0.1:7337`.
A physical iPhone needs a reachable LAN address or HTTPS server URL.
The server binds to loopback by default; configure its listen address before connecting from another device.
Allow the local network permission when iOS asks.

Connection credentials stay in the iOS Keychain. Provider keys are managed by the server.
The app permits HTTP connections for local development and user-configured servers. Use HTTPS outside a trusted local network.

For development, add `CRUMBLE_URL` and `CRUMBLE_TOKEN` to the scheme's environment variables.
Environment values override saved credentials. Keep real tokens out of shared schemes and source control.

## Features

- Create, edit, duplicate, pause, and delete agents.
- Configure models, instructions, capabilities, permitted bots, skills, and integrations.
- Follow continuous chats with streaming replies, older history, quoted replies, cancellation, and context summarization.
- Send optimistic messages immediately; retry failed sends without duplicating server requests.
- Attach photos and image or UTF-8 text files. Messages accept up to eight attachments.
- Select permitted bots from touch suggestions while typing an `@` mention.
- View bot-to-bot exchange cards with sender, recipient, status, questions, and answers.
- Manage shared and personal memory, bundled and optional skills, scheduled tasks, and execution activity.
- Configure shared and personal MCP servers, tokens, and OAuth sign-in.
- Manage provider API keys.
- Use an adaptive navigation list on iPhone and a sidebar on iPad.

The server remains the source of truth. Optimistic changes reconcile with confirmed records or roll back on failure.
Drafts and pending chat messages survive backgrounding while the app remains in memory.
On foregrounding, the app refreshes the selected chat and reconnects its event streams.

## Notifications and background behavior

The app can post local notifications for replies received while it runs, except for the chat you are viewing.
Tapping a notification opens that agent.
iOS suspends network streams in the background. This client does not provide APNs push delivery or continuous background execution.
Replies completed while the app is suspended appear when you return.
Unsent drafts are held in memory and do not survive termination by iOS.

OAuth uses an authentication browser session and the callback `dev.crumble.ios:/oauth/callback`.
Your MCP provider must accept that redirect URI.

## Build and test

Build without a signing account for the simulator:

```sh
xcodebuild -project Crumble.xcodeproj -scheme Crumble \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
```

Run tests with an available simulator:

```sh
./scripts/test.sh
```

The script selects the first available iPhone simulator. Set `CRUMBLE_SIMULATOR_ID` to use a specific device.
Tests cover API decoding, event parsing, attachments, notifications, mentions, optimistic operations, and connection setup UI.
The UI test uses an isolated launch without saved credentials.
Tests do not require a server or provider account.
Live model responses and third-party OAuth require configured services and separate device verification.
