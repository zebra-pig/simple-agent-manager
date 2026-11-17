# Native chat scrolling regression

The runner builds production `ChatView` and Rust bindings, serves loopback-only
HTTP fixture data, and uses XCUITest touch gestures and the actual down-arrow.
Only the isolated app entry point is replaced. No account credentials, live chat
mutation or VM provisioning is involved.

## Run

On an Apple silicon Mac with Xcode 26+ and an installed iOS runtime:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
gem install --user-install xcodeproj -v 1.27.0 --no-document
apps/native/scripts/build-ios.sh
bash apps/native/scripts/test.sh apple-ui .tmp/scroll-regression chat-scroll
```

The runner creates and deletes a dedicated iPhone simulator. Results include
`results.xcresult`, `xcodebuild.log`, `server.log` and screenshot attachments.
XCTest screenshots remain available on failure;
verbose simulator sysdiagnoses are disabled to bound collection time and disk use.
The Xcode Cloud post-clone hook runs this suite and exports its PNG attachments.

## Fifteen real UI tests

- Opening and polling at latest without fetching earlier pages.
- Jumping after multiple pages, with an observed intermediate rendered position.
- Response arrival while an actual swipe is moving: overlapping visible row
  identities and no discontinuity between adjacent display samples.
- A held history response completing during the jump animation, before arrival.
- Mixed Markdown, code, tables, tool cards and thoughts across three pages,
  including landscape/portrait rotation and another jump.
- Three stationary history loads for plain messages, and three for mixed content.
  Each captures before/after screenshots, requires the same message position
  within one point in every display sample, and prohibits chained requests.
- An older reading position through multiple background polls, including every
  display sample and a subsequent jump proving buffered live content catches up.
- A partially visible message through a held earlier-page response.
- Four repeated top-to-latest trips without draining history.
- The exact top → tap down-arrow → release held response sequence.
- All four provisioning stages and their disappearance when the agent starts.
- Wide content (unbroken tokens, long links, tables, long commands) in portrait,
  after a sideways drag, in landscape and back: every row stays within the
  screen and the conversation is never wider than, or scrolled sideways in,
  its scroll view.
- A long agent reply between library images, a multi-attachment upload and a
  pending request card, over four launches, polling, scrolling and a sideways
  drag. With content padding this offset the column 16 points sideways on
  roughly half of launches.
- Full-bleed layout: the conversation draws behind the navigation bar and the
  composer, while the resting latest row stays clear of both.

HTTP completion is asserted before insertion checks. A read-only display-link
probe samples the last layout, native presentation offset, content size and
insets. Raw layout callbacks are also logged: they can include intermediate
passes that never reach the display, so they are not sufficient evidence alone.
Probe batches are acknowledged in order. Tests wait for delivery through the
measured interval before evaluating captured frames, with a failure deadline.
The animation check requires nonzero travel and a rendered intermediate position;
it does not impose a minimum frame rate on a shared build machine.
XCTest screenshot attachments complement the measurements.
XCTest waits for quiescence before subsequent commands; the suite does not claim
an automated finger interruption in the middle of a 0.35-second jump animation.

## Implementation

The agent conversation uses a newest-first logical lazy stack with upright rows.
Older pages extend its far end, leaving existing message coordinates unchanged.
Visual order and VoiceOver message priorities remain chronological. SwiftUI owns
one scroll position and its animated top-edge destination (the visual latest end).
The normal private SAM conversation keeps its existing scroll implementation.

The 16-point column inset is a scroll view content margin, not padding inside
the lazy stack: a lazily realized row could be laid out at the full scroll width
and leave the conversation scrolled sideways. The scroll view is not clipped:
rows scroll behind the navigation bar and the composer, under a blurred fade
below the bar, because the system scroll edge effect is off for the inverted list.

Before publishing a changed reading snapshot, the Apple model captures the visible
message and fractional viewport anchor. The same SwiftUI position owner applies
that identity anchor synchronously, preserving active scroll velocity. Explicit
jumps invalidate reading preservation; another real drag resumes manual reading.
There is no UIScrollView offset-writing or timed restoration/retry loop.

While history is being read, live changes remain in the current core state and a
stable rendered transcript receives only newly fetched older items. Returning to
latest, naturally or using the arrow, immediately displays the current state.
Session/composer controls and polling continue updating during history reading.
This prevents offscreen streaming, notification and provisioning height changes
from moving the reading position.

Further automatic pager requests require a new downward drag; layout-driven
visibility reentry cannot admit another page. An explicit accessibility action can
load an earlier page without a touch drag. Retry remains available on failure.
In the shared core, loaded page boundaries prevent an existing reply or thought
from merging into an older card. Tool statuses resolve globally, with a stable
representative in the newest already-loaded page, avoiding duplicate tool cards.
