# Changelog

## Unreleased

- CI only builds the app and its tests with cached Swift packages and build products; tests need a simulator and run locally. `scripts/build.sh` runs the CI build, and `scripts/test.sh` accepts `unit`, `ui`, or `all`.
- Replace the local glossary with a link to the canonical glossary in the spec repository.
- Remove references to the obsolete agent folder field, as required by the current shared package and server contract.
- Adopt apfelkern's generated API operations, shared activity and push models, and event decoding without an app-local generator.
- Pin apfelkern by commit over HTTPS and run unsigned simulator tests in public-repository CI.
