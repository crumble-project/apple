# Crumble for iOS

Crumble is a native SwiftUI client for your Crumble server, built for iPhone and iPad.
It uses the same authenticated API as the macOS and Android apps through apfelkern's generated client.

## Requirements

- iOS or iPadOS 26 or later.
- Xcode 26 or later with the iOS SDK.
- A running Crumble server from the sibling `bot` directory.
- An Apple signing team to install on a physical device.

## Shared Swift package

The app and unit tests fetch `https://github.com/crumble-project/apfelkern.git` at the exact commit recorded in the Xcode project and `Package.resolved`.
A sibling checkout and SSH credentials are not required.
The package provides generated operations and event decoding, common domain models, API transport, drafts, and pure helpers. See the [package documentation](https://github.com/crumble-project/apfelkern).

## Update the API client

Update apfelkern first, then update its exact commit in `Crumble.xcodeproj/project.pbxproj` and resolve packages to refresh `Package.resolved`. Run the build, lint, and test commands in this README. API and event generation happen only in apfelkern; do not add a generator or duplicate wire models here.

Apfelkern initially consumes a checksum-verified local contract export. After bot's first release, its pin must switch to `contract-v1.0.0` before final app adoption. Merge bot, then apfelkern, then this app. The app keeps its connection settings, task cancellation, error presentation, optimistic delivery, and streaming lifetime.

`.github/workflows/ci.yml` runs the unsigned simulator unit tests on public GitHub-hosted macOS runners for every push and pull request. `.github/workflows/ui-tests.yml` runs the UI tests nightly and on demand, because they take minutes. Neither requires a signing account, server, or custom secret.

## Chat delivery ownership

The iOS app uses `BotChatDelivery` from `apfelkern` to coordinate pending messages, retry payloads, and previews. HTTP acceptance retains pending messages until a transcript snapshot confirms them. `AppModel` owns network tasks, composer state, connection and selection guards, and native image conversion. Delivery behavior tests live in `apfelkern`; controlled transport tests remain in the app.

## Open the project

Open `Crumble.xcodeproj` in Xcode and select the **Crumble** scheme.
Select an iPhone or iPad simulator, then run the app.
For a physical device, select your team under **Signing & Capabilities** before running.
The bundle identifier is `dev.crumble-project.ios`; change it if your signing account requires a unique identifier.

## Configure push notifications

Push notifications use Apple Push Notification service (APNs). You need an Apple Developer Program team with push access.

1. Enable **Push Notifications** for the explicit App ID `dev.crumble-project.ios` in your Apple Developer account.
2. Select the **Crumble** target and your team under **Signing & Capabilities**.
3. Refresh the provisioning profile so it includes Push Notifications and `aps-environment`.
4. Configure the server with `CRUMBLE_APNS_TEAM_ID`, `CRUMBLE_APNS_KEY_ID`, and `CRUMBLE_APNS_PRIVATE_KEY_PATH`.
5. Add `dev.crumble-project.ios` to the server's `CRUMBLE_APNS_ALLOWED_TOPICS`.
6. Run the signed app, save your server connection, and allow notifications.

A wildcard provisioning profile cannot provide push access. The project includes the Push Notifications capability and entitlement.
Debug builds use the APNs sandbox (`APNS_ENVIRONMENT=development`); Release builds use production (`APNS_ENVIRONMENT=production`).
The signing profile must match this environment. Override `APNS_ENVIRONMENT` when using a different signing configuration.
Keep APNs keys on the server, outside source control.

Verify actual delivery on a physical device, including foreground, background, terminated, and notification-tap launches.
Compatible simulators can receive sandbox APNs, but simulated payload injection alone does not verify provider delivery.

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

Completed replies notify with the agent name, a message preview, and the default sound.
Replies from delegated bots stay quiet. The visible chat stays quiet while the app is active.
Tap an alert to open its agent, including after a cold launch. Alerts from another server cannot switch your connection.

With server push configured, APNs can show alerts while the app is suspended or terminated.
The app stops posting local stream alerts when the server confirms remote delivery, preventing duplicate delivery paths.
Without remote delivery, local alerts work while the app receives the activity stream.
Use **Settings > Notifications** to disable reply alerts or open iOS notification settings.
iOS controls lock-screen previews, Focus filtering, and notification permissions.

Device registrations update after token rotation. Disabling notifications or changing servers removes the previous registration.
Failed removal stays in Keychain for retries on launch and while active. New remote registration waits for cleanup.
The settings status reports pending cleanup. Local fallback remains available for a different current server.
An unreachable previous server might continue sending alerts until cleanup succeeds.
Visible-chat suppression uses a presence lease refreshed every 30 seconds and expiring after 120 seconds.
A forced quit or lost connection can leave that lease active briefly. Push delivery is best effort.

The app stops network streams in the background and refreshes content when you return or open an alert.
It does not keep streams running through silent pushes. Unsent drafts stay in memory and do not survive app termination.

OAuth uses an authentication browser session and the callback `dev.crumble.ios:/oauth/callback`.
Your MCP provider must accept that redirect URI.

## Lint Swift code

Install [SwiftLint](https://github.com/realm/SwiftLint) with Homebrew:

```sh
brew install swiftlint
```

Run lint checks:

```sh
./scripts/lint.sh
```

The `.swiftlint.yml` configuration covers the app, unit tests, and UI tests, excluding generated build files.
It enables the listed opt-in rules alongside SwiftLint's default rules.
Lint runs separately from builds and tests. Errors fail the command; warnings do not.

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

Pass `unit` or `ui` to run only the unit or UI tests; without an argument, the script runs both. It boots the simulator while the app builds. The script selects the first available iPhone simulator. Set `CRUMBLE_SIMULATOR_ID` to use a specific device.
Tests cover API decoding, event parsing, attachments, notifications, mentions, optimistic operations, and connection setup UI.
The UI test uses an isolated launch without saved credentials.
Tests do not require a server or provider account.
Live model responses and third-party OAuth require configured services and separate device verification.
