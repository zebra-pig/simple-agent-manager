# Native Files and Git render evidence

Captured from the production FileBrowserView, GitChangesView, and SourceFileView
using offline mock transport records in Xcode Cloud build 77, source e6813b6de.
The macOS archive and standalone fixture renderer passed. These are NSHostingView
captures at 375 and 1000 logical points, 2x scale, not iPhone screenshots.

Inspected both widths: plain list separators, filenames and file sizes remain
aligned; long filenames truncate within the row; Git sections and rename paths
remain legible; error text wraps and Retry remains visible. Empty folder states
render without overlapping content. Diff line numbers and added/removed colors
remain distinct; long source text extends horizontally for scrolling.

Capture limitations: window navigation/search/toolbars are outside the hosted
content snapshot. Diff PNGs retain their original transparent background and
should be viewed over white (the fixture uses light mode). No image pixels were
changed. Native Back/swipe-back, retained scroll positions, horizontal source
scrolling, and live server retry behavior still require device verification.

Manual device checks:

1. Files: scroll and filter the root, open a folder, open its subfolder, open a
   file, then navigate Back through each destination. Confirm each parent keeps
   its filter and position. Refresh a nested folder and verify its path stays put.
2. Open one tracked file changed in both index and working tree through each Git
   section. Confirm diffs differ correctly. Open View file, then Back to its diff
   and Back to Git; the Git list and filter must remain intact.
3. Open an untracked file and a renamed file. Check contents and old/new paths.
4. Check empty directories, unmatched search, loading and offline/retry states.
5. Scroll a large file vertically and horizontally; test Dynamic Type and dark
   mode on iPhone and iPad as well as native macOS navigation.
