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

## Real UI tests

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
- Pressing message text selects a word in place, not the whole message. Its edit
  menu offers Comment, and Copy then Paste into the composer yields only that word.
  Pressing a message opens the comment sheet from that menu.
- Expanding and collapsing activity, thinking and tool output sections, one at a
  time and in quick succession, while reading and at latest during polling: the
  rows on screen never overlap.

Every test also fails if, in any display frame, two rows' cells overlap
(including a cell animating to a new position), or a row's content stays taller
than its cell for three measured frames. Rows passing under the navigation bar
or the composer used to measure taller by the part of the bar they were under.

HTTP completion is asserted before insertion checks. A read-only display-link
probe samples the transcript's visible rows (through its diffable data source),
content offset, content size and insets. Raw layout callbacks are also logged: they can include intermediate
passes that never reach the display, so they are not sufficient evidence alone.
Probe batches are acknowledged in order. Tests wait for delivery through the
measured interval before evaluating captured frames, with a failure deadline.
The animation check requires nonzero travel and a rendered intermediate position;
it does not impose a minimum frame rate on a shared build machine.
XCTest screenshot attachments complement the measurements.
XCTest waits for quiescence before subsequent commands; the suite does not claim
an automated finger interruption in the middle of a 0.5-second jump animation.

## Implementation

On iOS the agent conversation is an upright `UICollectionView`
(`ChatTranscript`), oldest row at the top, rows hosted with
`UIHostingConfiguration`. Nothing is mirrored. Earlier versions flipped a SwiftUI
lazy stack upside down. That broke the system scroll edge effect, context-menu
previews and in-place text selection. Signal-iOS, ChatLayout, MessageKit and
zulip-flutter all stay upright and correct the offset instead. Element X,
Telegram, exyte/Chat and Stream Chat flip.

`ChatTranscriptLayout` is a single-column, self-sizing layout. Three rules keep
what the reader sees still:

- While following the latest row, every layout pass pins the bottom.
- A data change (an earlier page, a resolved card) captures the first visible
  row and its distance from the top before applying the snapshot. It restores
  that distance in the same pass, before anything is drawn.
- When a row measures itself, the layout moves the content offset by the height
  change in the same invalidation (`contentOffsetAdjustment`). It does so when the
  row starts above the visible top, or when it is measured for the first time
  above a row the reader already sees. Rows the reader expands, or scrolls onto,
  grow downward.

The jump to latest is a 0.5-second eased animation driven per display frame.
Its destination follows the bottom as rows measure themselves on the way. An
earlier page arriving mid-jump shifts the start instead of restarting it.
Measurements are keyed by row identity, so they follow a row when a page is
inserted before it.

The transcript draws behind the navigation bar, under the system scroll edge
effect, and behind the composer. Its insets come from the SwiftUI safe area. The
scroll view adds the vertical safe area to its content insets itself
(`contentInsetAdjustmentBehavior = .scrollableAxes`), which leaves its rows with
no vertical safe area. With one, a hosted row under a bar was laid out and
measured taller by the part of the bar it was under, and shrank again as it
scrolled out. The 16-point column inset is the hosting configuration's margin.

Rows change height and position in one step. Their cells never animate to a new
position, and animations inside a row are off, so a section opening or closing
cannot draw over the next row. Open sections are kept per row
(`RowDisclosures`), not in the recycled cell, so a row keeps its height when it
scrolls away and back.

Message text is a non-editable `UITextView` (`SelectableText`): a press
selects a word with handles, the loupe and the system edit menu, and the edit
menu leads with Comment. The collection view's own context menu (Comment) only
opens for presses beside the text. macOS keeps a SwiftUI scroll view, where
`textSelection(.enabled)` already selects ranges.

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
