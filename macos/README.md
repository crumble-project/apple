# Crumble for macOS

Crumble for macOS is a native client built with [MyGo](https://mygo.egoist.dev/). It connects to a running Crumble server and provides agent management, one continuous chat per agent, streaming updates, memory, schedules, tools, approvals, and settings as those server capabilities become available.

## Swift app

`mac/` holds a SwiftUI port of this client, which is meant to replace the Go app. It needs macOS 26 or later and Xcode 26 or later. It reads the same Keychain entries as the Go app, so a saved connection carries over; macOS asks once whether the new app may read them.

Run the tests:

```bash
cd mac && swift test
```

Build `mac/build/Crumble.app`, signed ad hoc for local use:

```bash
cd mac && ./scripts/build-app.sh
```

`CRUMBLE_URL` and `CRUMBLE_TOKEN` work as they do for the Go app. Settings open with **⌘,** instead of from the sidebar.

## Requirements

- macOS 12 or later for the native MyGo runtime.
- Go 1.27.2 or later.
- A running Crumble server. Start the server from the sibling `bot` repository.

The repository pins MyGo `v0.5.5` as a Go tool in `go.mod`.

## Install dependencies

From this directory, download Go modules:

```bash
go mod download
```

The first build might download the pinned MyGo tool. If the tool is unavailable, install it with:

```bash
go get -tool github.com/egoist/mygo/cmd/mygo@v0.5.5
```

## Run the development app

Start the native development app:

```bash
go tool mygo dev
```

The app uses `http://127.0.0.1:7337` by default. Configure a different server without changing stored settings by setting these variables before starting the app:

```bash
CRUMBLE_URL="http://127.0.0.1:7338" CRUMBLE_TOKEN="REPLACE_WITH_A_SERVER_TOKEN" go tool mygo dev
```

`CRUMBLE_TOKEN` must be treated as a secret. The app also stores the server URL and token in the macOS Keychain under the `dev.crumble.desktop` service when you save connection settings.

## Verify the client

Run Go unit and view tests:

```bash
go test ./...
```

Build the native app bundle:

```bash
go tool mygo build
```

MyGo writes build output under `build/`, according to `mygo.json`. Use the platform and distribution options documented by the pinned MyGo release when you need a universal app or disk image.

The current build is an ad hoc macOS application. It is not notarized. Distribution requires a Developer ID signing identity, a provisioning configuration where applicable, and a separate notarization workflow on macOS.

## Connect to a server

1. Start the server from the `bot` repository.
2. Copy the token from the server's `server-token` file.
3. Open the app's connection settings.
4. Enter the server URL and token.
5. Save the connection.

The app sends the token as an `Authorization: Bearer` header. It does not send provider keys to the server during ordinary chat requests; provider credentials remain managed by the server.

## Current scope and limitations

The client contains native MyGo views, server connection setup, agent management, one continuous chat per agent with older-history loading and replies to earlier messages, streamed chat updates, memory and schedule panels, MCP configuration, delegation controls, and approval UI paths. The server remains the source of truth for persistent state.

The product is still under active development. Hermes Agent and Grok Bot parity is a target for end-to-end acceptance, not a statement that every capability is complete. Review the server's [`docs/product-parity.md`](../bot/docs/product-parity.md) and [`docs/architecture.md`](../bot/docs/architecture.md) before planning a release.

Known limitations include:

- A live server with valid provider credentials is required for model responses.
- macOS signing and notarization are not configured by this repository.
- The app targets macOS; other operating systems are outside the product scope.
- Native UI polish, recovery behavior, accessibility coverage, and parity acceptance tests continue to evolve.
