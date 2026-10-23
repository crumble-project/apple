# Crumble for iOS

Native SwiftUI client for iPhone and iPad, sharing [`../apfelkern`](../apfelkern/README.md) with the macOS app.

## Requirements

- iOS / iPadOS 26+ and Xcode 26+.
- A running Crumble server from the sibling `bot` repository.

## Run and connect

1. Open `Crumble.xcodeproj` in Xcode and run the **Crumble** scheme on a simulator or signed device.
2. Open **Settings**, enter your server URL (`http://127.0.0.1:7337` on Simulator, or your host's LAN/HTTPS address on a device) and `server-token`, and tap **Save Connection**.
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
