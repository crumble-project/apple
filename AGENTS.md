# Instructions

- `apfelkern` is the shared Swift package; `macos` and `ios` build against it by path. Land an apfelkern change and the app changes it needs in the same pull request.
- After changing apfelkern, run the checks for apfelkern and both apps. Each project's README lists its commands.
- iOS tests need a simulator, so CI only builds them. Run `ios/scripts/test.sh unit` locally before you push.
- `macos/AGENTS.md` holds the interaction principles for both apps.
