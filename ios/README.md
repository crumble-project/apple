# Crumble for iOS

Native SwiftUI client for iPhone and iPad, sharing [`../apfelkern`](../apfelkern/README.md) with the macOS app. Supports bot chats, group chats, coding jobs, memories, skills, scheduled tasks, MCP integrations, GitHub Apps and machine accounts, credentials and logins across bots, avatars, password managers, web search, judge and vision models, message gateways, the event relay and event sources, reverting skill and memory changes, System, Light, and Dark themes, command search, server administration, account sign-up, invite links, and sign-out, provider account sign-in, and live bot desktops with take-control by touch.

## Requirements

- iOS / iPadOS 26+ and Xcode 26+.
- A running Crumble server from the sibling `bot` repository.

## Run and connect

1. Open `Crumble.xcodeproj` in Xcode and run the **Crumble** scheme on a simulator or signed device.
2. Open **Settings**, enter your server URL (`http://127.0.0.1:7337` on Simulator, or your host's LAN/HTTPS address on a device), email, and password, and tap **Sign In**. To make an account, tap **Create an Account**, or paste an invite link into **Server URL**. **Sign Out** is in **Settings**.
3. For development overrides, set `CRUMBLE_URL` and `CRUMBLE_TOKEN` in the scheme's environment variables.

## Build and test

```sh
./scripts/build.sh        # Unsigned build of app and test targets (runs in CI)
./scripts/test.sh         # Run unit and UI tests on an available iPhone simulator
./scripts/test.sh unit    # Unit tests only
./scripts/test.sh ui      # UI tests only
swiftlint lint            # Lint Swift sources
```

## Push notifications

Without APNs configuration, the app posts local notifications while connected to `/v1/events`. For remote APNs delivery while suspended or terminated, sign the `dev.crumble-project.ios` App ID with Push Notifications enabled and configure `CRUMBLE_APNS_*` on the server (see `bot/docs/native-push.md`).

A reply that waits for the owner plays the web's approval or credential cue. A remote push uses the system sound until the app is open, because the server sets that sound in the APNs payload.
