# Apple tests

See [native testing](../../TESTING.md) for commands, CI, scope and evidence policy.

- `behavior/`: macOS XCTest against selected production Swift sources.
- `integration/`: real Swift ↔ Rust ↔ offline HTTP and image decoding checks.
- `ui/`: grouped simulator suites and their fixture app entry points.
- `support/`: shared project generation, simulator lifecycle and result handling.

`bash run.sh host|integration|ui|all <fresh-output-directory> [ui-suite]` is the
Apple entry point. UI suites using the shared runner contain `App.swift`,
`*Tests.swift` and an optional `server.py`; production views stay in `ios/SAM`.
Visual render tools live in `../../verification/visual`, outside the test suite.
