# Native chat scrolling regression

The regression runner builds production `ChatView` and Rust bindings, serves
loopback-only HTTP fixture data, and uses XCUITest touch gestures and the actual
Jump to latest button. It replaces only the isolated preview's app entry point;
it never reads account credentials or provisions a VM.

Run on an Apple silicon Mac with Xcode 26+ and an installed iOS runtime:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
gem install --user-install xcodeproj -v 1.27.0 --no-document
apps/native/scripts/build-ios.sh
apps/native/verification/chat-scroll/run.sh /tmp/sam-scroll-regression
```

The runner creates and deletes a dedicated iPhone simulator. The results are in
`scroll-tests.xcresult`, `xcodebuild.log`, `server.log` and `interaction.mov`.
The iOS Xcode Cloud post-clone hook runs this suite on its Mac host and exports
XCTest PNG screenshots into the build log even on failure.

## Coverage

Nine real UI tests cover:

- Opening/polling at the bottom without fetching earlier pages.
- Jumping after multiple pages and staying at the latest message through two
  poll cycles with changing message height. A read-only display-link probe
  requires intermediate rendered offsets to prove the button actually animates.
- Mixed Markdown/code/tool/thinking messages across three pages and rotation.
- Four repeated top-to-bottom jumps without recursive pagination.
- Preserving an older reading position through polling.
- Preserving a partially visible message's position when an earlier page arrives,
  after explicitly asserting that the HTTP response completed.
- All four inline provisioning stages and disappearance when the agent starts.
- A response completing during the actual jump animation after leaving and
  reentering the pager, without starting a canceled request or restoring the top.
- The user's exact top → tap sequence: hold an earlier-page HTTP response, swipe
  to the top, tap the real down-arrow, release the response and observe two polls.

The suite uses fixture conversations rather than the user's authenticated chat.
It does not automate a finger interrupting an animation during its 0.35-second
transition; XCTest waits for quiescence before subsequent commands. It verifies
that subsequent real gestures and jumps work and that no background scroll loop
continues after settling.

## Implementation

SwiftUI owns one semantic scroll position and the animation to its bottom edge.
There is no underlying UIScrollView offset-writing/retry loop. The actual bottom
sentinel's viewport visibility controls following. The history pager uses its
frame in the viewport and requests one page per visibility transition, never on
loading completion alone. Main's `ChatHistoryAnchor` preserves the original row
and pixel offset through insertion; restoration uses the same position owner as
the button. An explicit jump invalidates both pending history anchors.

## Mac execution history

The earlier programmatic scroll-controller fixture missed the real interaction.
Its historical screenshots are not evidence for this correction.

| Xcode Cloud build | Source | Result |
| --- | --- | --- |
| 91 | 9b2f2ba0f | Harness failed before UI execution; fixed generated test PRODUCT_NAME and missing Loading.swift in the existing macOS render compile. |
| 93 | 9ec7f2ad4 | macOS archive passed; six UI tests ran and failed. Fixed bottom visibility, String-ID pager tracking and an XCTest label-query limit. |
| 99 | a83c4ecbf | macOS archive passed; seven UI tests ran, four passed and three failed. Exact top→tap with held response, four repeated jumps, bottom polling and older-position polling passed. Consecutive pagination and prepend position failed. |
| 101 | de42ba06a | macOS archive passed; eight UI tests ran, five passed and three failed. Provisioning passed. Prepend now retains the row but shifts 24pt; consecutive page entry can be dropped during loading. |

Build 103 (784daaa5a) ran eight UI tests: six passed, two failed. Updating the
reading anchor while the response waited fixed the24pt shift. Consecutive pages
still stalled when the pager stayed visible through repeated swipes. The next
correction admits a new downward finger swipe at the continuously visible top,
without treating completion as new intent. A cancellation generation invalidates
pending entries when the arrow is tapped. A ninth UI test releases and completes
history during the actual animation and checks the remaining distance at both
points. Test-only layout/inset measurements remain available in the logs. No passing full-suite result
is claimed until all test results and screenshots have been inspected.
