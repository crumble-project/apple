# Notifications on macOS

Crumble for macOS shows native local notifications for replies from your own
Crumble server. The app receives replies over the server's authenticated
`/v1/events` stream and posts them with `UNUserNotificationCenter`. Crumble
uses no APNs, push gateway, device registration, or provider tokens, so the
app must be running to receive notifications.

## What notifies

- A finished reply notifies unless you are looking at that bot's chat. That
  means Crumble is active and its main window is on screen, not closed,
  hidden, or minimized.
- Replies that a bot delegated to another bot stay quiet, because the
  delegating bot reports back itself.
- Each reply notifies at most once. Crumble remembers the most recent 512
  reply event IDs for each server URL, including across relaunches.
- Newer replies from a bot replace that bot's earlier notification.
- Notifications follow the **Notifications** switch in Settings, macOS
  notification permission, and Focus. macOS asks for permission on first
  launch. The app rechecks permission each time it becomes active.
- A binary started with `swift run` has no bundle ID and posts no
  notifications. Build the app with `./scripts/build-app.sh`.

## Lifecycle states

| State | Notifications |
| --- | --- |
| Active, viewing the bot's chat | None for that bot. Other bots notify. |
| Active, another chat or the Settings window | Yes. |
| In the background, hidden, or minimized | Yes. |
| Main window closed, app still running | Yes. Closing the last window doesn't quit Crumble. Click the Dock icon or a notification to reopen it. |
| Mac asleep | None. The streams reconnect on wake. |
| Network offline | None. The streams reconnect when the network returns. |
| Server restarting or unreachable | None. The streams retry with backoff of up to 8 seconds. |
| Crumble quit | None. |

Crumble doesn't notify for replies that finished while it was asleep, offline,
disconnected, or quit. The server doesn't replay finished replies, and its
streams have no `Last-Event-ID` replay. After reconnection, Crumble restores
state from the server instead:

- Each chat stream sends the current snapshot on connection. That updates the
  open chat's transcript and the running state of bots you left mid-reply.
- The activity stream replays each bot's latest preview on connection. Its
  first event after a reconnect reloads the bot list, so bots created or
  deleted meanwhile appear or disappear. Pending local edits are kept.

## Reconnection

The streams reconnect when they close or fail, and when the Mac wakes or the
network path returns or moves to another interface. The server sends a
heartbeat every 15 seconds, and a stream that receives nothing for 45 seconds
fails and reconnects. A connection that drops silently, such as when the
server's host loses power, therefore recovers within about a minute.

An authentication failure stops the streams until you save a working
connection in Settings.

## Clicking a notification

A click activates Crumble, reopens the main window, and opens the bot's chat.

- A notification from a server other than the connected one shows an error
  naming that server instead of opening a chat.
- A bot missing from the sidebar is looked up on the server again. If it was
  deleted, Crumble shows an error and keeps the current chat.

## Launch at login

Crumble doesn't register a login item or a background helper. To keep
notifications coming after a restart, add Crumble in **System Settings** >
**General** > **Login Items & Extensions**.

## Verify notifications

Run the unit tests and the bundle check:

```sh
swift test
./scripts/check-app-bundle.sh
```

The bundle check builds `Crumble Dev.app` in a temporary folder. It checks the
bundle ID and signature, and that the bundle has no APNs entitlement. It
doesn't launch the app.

Check these against a running server with the built app:

1. Finish a reply while viewing another bot; expect one notification with
   sound.
2. Finish a reply in the open chat; expect no notification.
3. Close the main window, finish a reply, and click the notification; expect
   the chat to open.
4. Put the Mac to sleep, wake it, and finish a reply; expect one notification.
5. Turn Wi-Fi off and on, and restart the server; expect the connection status
   to recover and missed replies to appear in the chat without notifications.
6. Switch servers, then click a notification from the previous server; expect
   an error naming that server.
7. Delete a bot from another client, then click its notification; expect an
   error.
