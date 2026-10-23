# Notifications on macOS

Crumble for macOS delivers local notifications from the server's `/v1/events` stream using `UNUserNotificationCenter` (no APNs required). Requires the app bundle built by `./scripts/build-app.sh` (`swift run` has no bundle ID).

## Rules

- **What notifies:** Completed bot chat replies, bot answers to coding/desktop job reports (titled with the job name), and group chat `@owner` mentions or first bot answers to an owner message—unless that chat is currently visible in the active main window.
- **Deduplication:** Remembers the latest 512 event IDs per server across relaunches; newer replies from a bot replace its previous notification.
- **Click action:** Opens the corresponding bot or group chat (and opens the bot desktop window for desktop job notifications), verifying that the notification matches the currently connected server.

## Lifecycle

| App / Connection State | Notifications |
| --- | --- |
| Active, viewing that chat | Suppressed for the visible chat; other chats notify. |
| Active (other chat / Settings), backgrounded, hidden, or main window closed | Delivered. |
| Quit, Mac asleep, offline, or server unreachable | None; state catches up silently on reconnect without replaying old alerts. |

## Verify

```sh
swift test
./scripts/check-app-bundle.sh
```
