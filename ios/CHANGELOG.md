# Changelog

## Unreleased

- Run only unit tests in CI on push and pull requests, caching Swift packages and booting the simulator during the build; UI tests run nightly and on demand. `scripts/test.sh` accepts `unit`, `ui`, or `all`.
- Replace the local glossary with a link to the canonical glossary in the spec repository.
- Remove references to the obsolete agent folder field, as required by the current shared package and server contract.
- Adopt apfelkern's generated API operations, shared activity and push models, and event decoding without an app-local generator.
- Pin apfelkern by commit over HTTPS and run unsigned simulator tests in public-repository CI.
