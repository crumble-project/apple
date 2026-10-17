# MyGo research for Crumble

Research checked 2026-10-17 against the official MyGo site and the `egoist/mygo` repository. The current documented release is **MyGo 0.5.5**. The Context7 library match is `/egoist/mygo` (high source reputation); the pinned source tag below is `v0.5.5`.

## What MyGo provides

MyGo is a pure-Go desktop framework with two window modes:

- **Native UI:** Go views built with `github.com/egoist/mygo/ui`, rendered by MyGo's GPU renderer (Metal on macOS), with no HTML, JavaScript, or webview.
- **Web frontend:** any frontend stack in the system webview (WKWebView on macOS), with typed TypeScript IPC generated from exported Go methods/events.

Both modes share windows, menus, tray, dialogs, notifications, clipboard, dark mode/accessibility, secrets, global shortcuts, deep links, file associations, and other desktop APIs. A Crumble client can therefore keep the high-frequency agent UI native while using a web window only if a rich editor or existing web component later justifies it.

Sources: [MyGo overview](https://mygo.egoist.dev/docs), [official homepage](https://mygo.egoist.dev/).

## Prerequisites and exact setup

The current docs require **Go 1.27 or later**. Native UI projects need Go alone; Bun is only required for projects with a web frontend. MyGo uses no cgo by default, so no C toolchain is needed. Native apps run on macOS 12 or later and draw with Metal. A Mac is required for macOS signing and disk-image generation.

Create a native project (the generated module pins the CLI as a Go tool):

```sh
go run github.com/egoist/mygo/cmd/mygo@latest init -template native crumble-desktop
cd crumble-desktop
go tool mygo dev
go test
go tool mygo build
```

The native template contains `main.go`, `main_test.go`, `go.mod`, `mygo.json`, and `resources/icon.png`. `go get -tool github.com/egoist/mygo/cmd/mygo@latest` updates the pinned CLI. `mygo doctor` validates the development machine.

The framework module at tag `v0.5.5` declares `go 1.27.1`; the core import path is `github.com/egoist/mygo`. The Liquid Glass plugin is imported as `github.com/egoist/mygo/plugins/glass`.

Sources: [Getting started](https://mygo.egoist.dev/docs/getting-started), [go.mod at v0.5.5](https://raw.githubusercontent.com/egoist/mygo/v0.5.5/go.mod), [requirements](https://mygo.egoist.dev/docs#requirements).

## Minimal working native app

This is the smallest useful shape for a Crumble shell: stateful Go view, native window, and the normal MyGo lifecycle.

```go
package main

import (
    "log"
    "github.com/egoist/mygo"
    "github.com/egoist/mygo/ui"
)

type app struct{ connected bool }

func (a *app) view(c *ui.Context) {
    ui.Column(c).Fill().Center().Gap(12).Children(func() {
        ui.Text(c, "Crumble").FontSize(28).Bold()
        label := "Connect"
        if a.connected { label = "Connected" }
        if ui.PrimaryButton(c, label).Clicked() { a.connected = !a.connected }
    })
}

func main() {
    a := &app{}
    mygo.App.WhenReady(func() {
        mygo.NewWindow(mygo.WindowOptions{
            Title: "Crumble", Width: 980, Height: 700,
            Content: ui.View(a.view),
        })
    })
    if err := mygo.App.Run(); err != nil { log.Fatal(err) }
}
```

This follows the official `counter-native` example and can be tested without opening a window through `main_test.go`/`ui.Tester`; that is useful for deterministic UI state and interaction tests.

Source: [official native counter example](https://raw.githubusercontent.com/egoist/mygo/v0.5.5/examples/counter-native/main.go).

## Liquid Glass and native macOS presentation

The official `glass` plugin is pure Go and has no JavaScript package or `mygo.Use` registration. It provides:

```go
import "github.com/egoist/mygo/plugins/glass"

ui.Row(c).
    Padding(8, 16).
    Radius(22).
    Material(glass.Glass{}).
    Children(func() { ui.Text(c, "On glass") })
```

`glass.Glass` is a `ui.Material`; `glass.Regular` is the default, `glass.Clear` is for media/photo surfaces, `Tint` adds an accent tint, and `Interactive: true` gives a pressed expansion similar to macOS interactive glass. `glass.ScrollEdge` models the soft/hard edge effect under bars, and `glass.Blur` supplies even or masked progressive backdrop blur. The plugin's shaders target Metal/HLSL/GLSL and a CPU renderer fallback.

For a first-class Mac shell, the official `examples/vibrancy` pattern is directly relevant: use `WindowOptions{TitleBarStyle: mygo.TitleBarHiddenInset, TitleBarHeight: 52, Vibrancy: mygo.VibrancySidebar}`; leave the root/sidebar background transparent so the system material shows through; use `c.TitleBar()` to inset content beside traffic lights; and call `win.SetVibrancy(...)` when the user changes material. The example also uses `DragWindow()` for custom title-bar regions. This is the practical starting point for Crumble's sidebar + conversation pane layout.

Sources: [Glass docs](https://mygo.egoist.dev/docs/plugins/glass), [Glass source README at v0.5.5](https://raw.githubusercontent.com/egoist/mygo/v0.5.5/plugins/glass/README.md), [vibrancy example](https://raw.githubusercontent.com/egoist/mygo/v0.5.5/examples/vibrancy/main.go).

## Desktop APIs relevant to Crumble

The `mygo` package exposes system behavior needed by a persistent agent client:

- `mygo.NewNotification` / `App.OnNotificationClick` for task completion and conversation notifications; packaged macOS apps are required for notifications.
- `mygo.Dialog.Open`, `.Save`, and `.Message` for import/export, destructive-action confirmation, and permission prompts; `Parent` attaches a sheet on macOS.
- `mygo.Clipboard` for text, HTML, images, and file lists; `mygo.Shell.OpenExternal`, `OpenPath`, `ShowItemInFolder`, and `TrashItem` for file/tool workflows.
- `mygo.Theme` and `Theme.Preferences()` for light/dark mode, accent color, reduce-motion, reduce-transparency, high-contrast, and text-scale settings. Native `ui` follows these defaults.
- `mygo.Power.KeepAwake` plus suspend/resume/lock callbacks for long-running agent executions.
- `mygo.Network.Status` and `OnChanged` for offline/reconnect UI; `mygo.Secrets` (documented desktop API) is the appropriate integration point for credentials.
- `mygo.NewTray` and `mygo.NewMenu` for a menu-bar surface, global shortcuts for quick capture, and app/window APIs for focus, hide/show, full-screen, bounds, and title-bar behavior.

Source: [Desktop APIs](https://mygo.egoist.dev/docs/native), [menus and tray](https://mygo.egoist.dev/docs/menus), [windows](https://mygo.egoist.dev/docs/windows).

## Build, signing, and distribution

`go tool mygo build` writes `build/<os>-<arch>/My App.app` and a macOS DMG. `-platform darwin/universal` combines arm64 and amd64; MyGo can cross-compile because it uses no cgo, but macOS signing/DMG/notarization steps run only on a Mac. Keep the app identifier stable once released because macOS keys preferences, permissions, and registrations by it. Configure name, reverse-DNS identifier, version, and optional `macos.signingIdentity` in `mygo.config.ts` (web projects) or the native project configuration.

Source: [building and distributing](https://mygo.egoist.dev/docs/distribution).

## Recommendation for Crumble

Start with a **native UI-only** MyGo app. It directly satisfies the macOS-first requirement, avoids a bundled browser, gives immediate startup and low memory use, and has first-party Liquid Glass/vibrancy primitives. Use a small Go adapter layer for the bot API and event streams, and keep network/storage code outside view functions so views remain deterministic and testable. Add a web window only for a specific capability that native UI cannot provide efficiently.

The first vertical slice should be: native sidebar + agent list, native conversation pane, streamed event state updated on a goroutine, `glass.ScrollEdge` for the conversation toolbar, `glass.Glass` for floating composer/actions, `mygo.Network` offline state, and `mygo.NewNotification` for background task completion. Build with `go test` and `go tool mygo build` on macOS before adding signing/notarization automation.

