# Chat image gallery regression

The gallery opens at the tapped file ID and immediately allows paging through
already-loaded user uploads and library images. There is no page indicator,
Previous/Next button, or history-loading footer. Loading older chat history never
replaces or disables the pager.

A separate reader discovers older images without prepending the conversation
behind the sheet. It publishes each history page as it arrives and stops once an
earlier image batch is found. Visiting the leading image requests another batch.
Pages without images are searched in the background while existing images remain
browsable. Source images stay in chronological order while the reader catches up
to history that the conversation had already loaded. Duplicate file IDs are
removed, and selection is a file ID rather than a position. History errors retain
the loaded images and offer retry. Reopening starts at the newly tapped image.

The chat screen owns presentation rather than recyclable message rows. Mac
navigation supports arrow keys and horizontal trackpad gestures. One gesture
advances one image; momentum cannot advance again or reverse it. Zoomed panning
and vertical scrolling do not navigate between images. Accessibility adjustment
remains available on the gallery without a visible counter.

Run on an Apple-silicon Mac after `apps/native/scripts/build-ios.sh`:

```sh
bash apps/native/ios/tests/gallery-macos.sh /tmp/sam-gallery-mac
# Requires the same xcodeproj Ruby gem as the existing chat-scroll runner.
bash apps/native/ios/tests/gallery-ios.sh /tmp/sam-gallery-touch
```

The Mac fixture uses production SwiftUI, Rust and HTTP transport with three
history pages and nine mixed images. It verifies the actual decoded pixels in
the native zoom view, traverses every image repeatedly, checks that the original
transcript is unchanged, and sends real AppKit events to check momentum and zoom.
An unavailable-image page must remain navigable. Screenshots are retained.

The iOS XCTest reproduces the reported two-image case with history requests held
open by the offline API. It swipes both ways before releasing history, releases
a batch during a swipe, browses newly found images while another older request
is held, then traverses every image twice and dismisses/reopens. It checks actual
navigation titles and explicitly rejects the old counter/loading footer. The
runner creates and deletes its own simulator and retains an xcresult bundle and
interaction video. Each run uses its own server port and checks that its server
started before building, so stale fixtures cannot be mistaken for the current
run. Both regressions run from the native Xcode Cloud post-clone
script. No live accounts or user images are used.

Review captures: [Mac gallery](evidence/gallery/mac.png),
[Mac unavailable image](evidence/gallery/mac-unavailable.png),
and [iOS gallery](evidence/gallery/ios.png).

Verified on filmkit-macbuild, 2026-11-16: Mac native regression passed; the
held-history iOS touch regression passed with zero failures in 111.116 seconds.
