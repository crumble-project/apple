# Crumble for Apple platforms

The Crumble apps for macOS and iOS and the Swift package they share.

| Directory | Contents |
| --- | --- |
| [`apfelkern`](apfelkern/README.md) | Shared Swift package: the generated API client, domain models, delivery state, and bot avatars. |
| [`macos`](macos/README.md) | Crumble for macOS, a Swift package. |
| [`ios`](ios/README.md) | Crumble for iOS and iPadOS, an Xcode project. |

Both apps depend on `../apfelkern` by path, so a change to apfelkern is built and tested with both apps in the same pull request. There is no apfelkern revision to pin.

apfelkern still pins a published bot contract release in `apfelkern/Contract`. See [Update the API client](apfelkern/README.md).

## Continuous integration

Each project has its own workflow in `.github/workflows`, which runs only when its directory or apfelkern changes:

- `apfelkern.yml` checks the generated client, builds, tests, and lints apfelkern.
- `macos.yml` runs the macOS app's tests.
- `ios.yml` builds the iOS app and its tests. iOS tests need a simulator and run only locally.
- `apfelkern-update-contract.yml` checks weekly for a new bot contract release and opens a pull request for it.

## History

This repository merges the former `crumble-project/apfelkern`, `crumble-project/desktop`, and `crumble-project/ios` repositories with their history. Pull request references in imported commit messages, such as `crumble-project/desktop#10`, point to those repositories.

The project's canonical glossary and feature specifications live in [`crumble-project/spec`](https://github.com/crumble-project/spec).
