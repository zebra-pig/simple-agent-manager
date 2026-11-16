# Chat image gallery regression

The gallery opens at the tapped file ID and includes user uploads and library
images across all chat history, in chronological order with duplicate file IDs
removed. A separate reader fetches older pages without prepending the visible
conversation. While it loads, the tapped image remains visible with progress;
paging starts once the collection is complete. A history error preserves loaded
images and offers retry. The collection stays fixed until dismissal, so polling
cannot reorder a swipe in progress. Reopening starts at the newly tapped image.

The screen owns presentation rather than its recyclable message rows. Mac
navigation supports visible buttons, arrow keys and horizontal trackpad gestures.
One gesture advances one image; momentum cannot advance again or reverse it.
Zoomed panning and vertical scrolling do not navigate between images.

Run on an Apple-silicon Mac after `apps/native/scripts/build-ios.sh`:

```sh
bash apps/native/ios/tests/gallery-macos.sh /tmp/sam-gallery-mac
# Requires the same xcodeproj Ruby gem as the existing chat-scroll runner.
bash apps/native/ios/tests/gallery-ios.sh /tmp/sam-gallery-touch
```

The offline API uses three pages containing nine images, mixed uploaded and
library files, and an unavailable image. The Mac fixture uses production SwiftUI,
Rust and HTTP transport. It checks the tapped image's final position, traverses
every image repeatedly, verifies the original transcript is unchanged, and sends
real AppKit scroll events to check momentum and zoom. Screenshots are retained;
Vision reads the displayed counters using CPU devices for headless build hosts.

The iOS XCTest opens an actual production chat attachment, swipes every gallery
page in both directions twice, checks both boundaries, dismisses, and reopens.
The runner creates and deletes its own simulator and retains an xcresult bundle
and interaction video. Both fixtures run from the Xcode Cloud post-clone script.
No live accounts or user images are used.
