# Native project chat search verification

The fixture hosts the production `ProjectView` with the real Rust view model,
HTTP client, observation relay and generated Swift bindings. Its local server
requires the fixture cookie and returns two valid rows from the first 50-row
window, then an older Unicode-titled chat at offset 50. No live account or task
is used. The fixture is outside the application source tree.

Captured on an isolated iPhone simulator with Xcode 27 / iOS 27. The harness
sets the system search bar and invokes its public delegate/updater callbacks;
this exercises the SwiftUI binding → Rust intent → observed filtered rows path.
All five captures were visually inspected:

| State | Evidence | Observed result |
| --- | --- | --- |
| Initial | [all.png](all.png) | All three chats, including the older page |
| Title | [title.png](title.png) | `  CAFÉ  ` finds only `Café release — 日本語` |
| Session ID | [id.png](id.png) | `old-session` finds the same older chat |
| No match | [no-results.png](no-results.png) | System no-results view includes the query |
| Cleared | [cleared.png](cleared.png) | All three rows return |

Reviewed search visibility, composer separation, row identity, Unicode, the
untitled fallback and empty-state readability. No overlap or clipping was found.
These captures do not verify physical typing, keyboard gestures, tapping result
rows, VoiceOver, or macOS runtime appearance. Native navigation uses the existing
unchanged row action. Both production iOS Simulator and macOS builds passed.

## Reproduce

Generate bindings with `apps/native/scripts/build-ios.sh`, then run:

```sh
sh apps/native/verification/project-search/render.sh /tmp/sam-project-search
```

The script builds an isolated copy of the Apple app with the fixture entry point,
creates a simulator, starts its loopback HTTP server, drives each search state,
and copies captures to the requested directory. It removes the simulator, app,
server and temporary build directory on exit. `SAM_SEARCH_DEVICE_FAMILY=iPad`
selects an available iPad device instead. Review the images after capture;
`CAPTURED` means the harness finished, not that image contents were asserted.

## Automated and build checks

- `cargo test --all-targets`: 84 tests passed, including two new authenticated
  HTTP capability tests in `core/tests/project_search.rs` (zero failures).
- `cargo clippy --all-targets -- -D warnings`: passed.
- `ios/ci_scripts/ci_post_clone.sh` with `CI_PRODUCT_PLATFORM=macOS`: passed,
  including resource/file renders, chat checks, project loading-sheet regression,
  all Apple Rust targets, binding generation and uploaded-preview transport checks.
- Regenerated all Apple libraries after the offset-window correction and rebuilt
  the production iOS Simulator and macOS targets: both passed.
- Shell syntax, JSON catalog validation and `git diff --check`: passed.

This native-only change does not modify or deploy the server/web application.
Its verification deployment is the isolated native simulator app above. No live
staging login, agent submission, or TestFlight distribution is claimed.
