# Configure macOS push signing

The build script creates a local ad hoc app by default. A provisioned build
requires an Apple Developer account, a signing identity, and a provisioning
profile for the app's bundle ID: `ng.crumbli.mac`, or `ng.crumbli.mac.dev` for
a build with `CRUMBLE_VARIANT=dev`.

## Create the Apple identifiers

1. Create an App ID with the bundle ID `ng.crumbli.mac` in [Certificates,
   Identifiers and Profiles](https://developer.apple.com/account/resources/).
2. Enable Push Notifications for the App ID.
3. Create a macOS development provisioning profile and an Apple Development
   certificate for local testing.
4. Create a Developer ID Application certificate and a distribution profile for
   outside-the-Mac-App-Store distribution.

The profile must include the macOS APS environment entitlement. Development
profiles use `development`. Distribution profiles use `production`.

Apple describes this entitlement as `com.apple.developer.aps-environment` in
the [APS Environment (macOS) entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).
Enable Push Notifications before you create the profile, as described in
[Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).

## Build a provisioned app

Set these variables for each development build:

```sh
export CRUMBLE_SIGNING_IDENTITY='Apple Development: NAME (TEAMID)'
export CRUMBLE_PROVISIONING_PROFILE="$PWD/NAME.provisionprofile"
export CRUMBLE_PUSH_ENVIRONMENT=development
export CRUMBLE_APP_OUTPUT="$PWD/build-push"
scripts/build-app.sh release
```

Replace `NAME` with the profile filename and the certificate owner. Use the
Developer ID identity with `production` and a distribution profile. The script
validates all three values before it removes the output app. If any value is
missing, the script fails instead of producing a partially configured signed
app.

For a `production` build, the script adds a secure timestamp and enables the
Hardened Runtime. These options are required for Developer ID notarization.

The resulting app contains `Contents/embedded.provisionprofile`, the
`com.apple.application-identifier`, `com.apple.developer.team-identifier`,
and `com.apple.developer.aps-environment` entitlements, and the
`CrumblePushEnvironment` key in `Contents/Info.plist`. The key is metadata for
the client. It does not create an APNs credential or send a push.

## Verify a signed app

Run these commands after a provisioned build:

```sh
codesign --verify --deep --strict build-push/Crumble.app
codesign --display --entitlements :- build-push/Crumble.app
security cms -D -i build-push/Crumble.app/Contents/embedded.provisionprofile
```

The first command verifies the signature. The second command must show the
three push entitlements. The profile output must match the signing identity,
bundle ID, team, and APNs environment.

## Complete distribution setup

Developer ID apps need notarization before distribution outside the Mac App
Store. Submit the signed app with `notarytool`, staple the ticket, and verify
the stapled app with `spctl`. Keep the Apple signing identity and APNs provider
credentials on the build or server system. Do not put those credentials in
the Crumble client repository.

The shared registration and push payload contract is documented in
`../bot/docs/native-push.md` when the backend work lands. A real delivery test
also needs the server-side APNs provider key and a registered device token.

## Use local notifications before provisioning

Account setup and live provider testing are deferred. With no signing variables,
`scripts/build-app.sh` still builds an ad hoc app. It uses local notifications
from the live server stream. New replies cannot notify while that app is quit
or disconnected. Running with `swift run` does not post system notifications.

Open **Settings** to enable or disable **Notifications**, inspect connection
status, or open macOS notification settings. The default remains a bot name,
a short reply preview, and sound. Replies in the active chat and delegated
bot replies remain quiet. macOS notification settings and Focus can prevent
presentation even when registration succeeds.

A provisioned build registers its APNs token on launch, then refreshes its server
registration and visible-chat presence every 30 seconds. A successful remote
registration owns notification delivery, so live stream events update the UI
without posting a second local alert. Event IDs are remembered across launches.
A notification tap validates the originating server before opening its bot chat.

Changing servers or disabling notifications queues removal of the previous
registration. Pending removal credentials stay in Keychain and retry while the
app runs. An unreachable previous server can keep sending alerts until removal
succeeds. Revoked credentials require server-side removal of the registration.
Visible-chat presence expires after 120 seconds when the app cannot clear it.
Normal quit attempts to clear presence before exiting. Abrupt termination can
therefore suppress a reply for the remaining lease. APNs delivery is best effort.

## Complete the deferred delivery check

After signing and provider credentials are configured:

1. Launch the provisioned app and allow notifications.
2. Confirm **Remote notifications connected** in Settings.
3. Finish a reply while viewing another bot; expect one alert with sound.
4. Finish a reply in the active chat; expect no alert.
5. Quit Crumble, finish a reply, and select its notification; expect the correct chat.
6. Disable notifications, rotate the device token, and change servers; verify old registrations are removed.
7. Disconnect and reconnect the network; verify retries without duplicate alerts.

These steps have not been verified against live APNs. No provider credentials,
provisioning profiles, or account changes are created by this implementation.
