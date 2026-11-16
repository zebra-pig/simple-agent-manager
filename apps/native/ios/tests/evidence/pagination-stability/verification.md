# Chat pagination verification — 2026-11-16

Production `ChatView`, the Rust model, UniFFI and real loopback HTTP pagination
were exercised by touch gestures in an isolated iPhone 16 Pro / iOS 27.0 simulator
with Xcode 27.0. The final viewport-clipped suite executed **12 tests: 12 passed,
0 failed, 0 skipped**, in 473.958 seconds. The machine-readable XCTest summary is
[test-summary.json](test-summary.json).

## Reading position measurements

Each response is held until the real swipe settles, then released. The server
must confirm completion. The same message must remain present and within 1pt in
every display-link sample; the final XCTest frame must also stay within 1pt.
After each load the test waits again and asserts the request count is unchanged.

| Conversation | Load | Before Y (pt) | After Y (pt) | Final drift |
| --- | --- | ---: | ---: | ---: |
| Plain | 1 | 158.000 | 158.000 | 0 |
| Plain | 2 | 158.000 | 158.000 | 0 |
| Plain | 3 | 137.000 | 137.000 | 0 |
| Mixed Markdown/tool/thought | 1 | 158.333 | 158.333 | 0 |
| Mixed Markdown/tool/thought | 2 | 158.000 | 158.000 | 0 |
| Mixed Markdown/tool/thought | 3 | 158.333 | 158.333 | 0 |

Background polling is checked over ten seconds with the same display-frame
invariant. Polling continues during history reading; returning to latest must
show a streaming version at least as recent as the completed polls. Separate
cases verify a response during actual movement, a response during the arrow's
animation, four repeated jumps, the exact held-response top→arrow sequence,
portrait/landscape rotation, initial loading and provisioning.

## Screenshots

These are original simulator PNG attachments, not edited mockups. All sixteen
captures were visually reviewed. The final clipping keeps content out of the
navigation title/status area and the composer/home-indicator area.

| Load | Before | After |
| --- | --- | --- |
| Plain 1 | [Before](plain-page-1-before-prepend.png) | [After](plain-page-1-after-prepend.png) |
| Plain 2 | [Before](plain-page-2-before-prepend.png) | [After](plain-page-2-after-prepend.png) |
| Plain 3 | [Before](plain-page-3-before-prepend.png) | [After](plain-page-3-after-prepend.png) |
| Mixed 1 | [Before](mixed-page-1-before-prepend.png) | [After](mixed-page-1-after-prepend.png) |
| Mixed 2 | [Before](mixed-page-2-before-prepend.png) | [After](mixed-page-2-after-prepend.png) |
| Mixed 3 | [Before](mixed-page-3-before-prepend.png) | [After](mixed-page-3-after-prepend.png) |
| Background polls | [Before](polling-before.png) | [After](polling-after.png) |

[Latest content after catching up](latest-caught-up.png) ·
[After rotation and jump](after-rotation.png)

Additional pixel checks on these captures used unmodified RGB regions:

- Mixed page 3, `crop=1080:900:50:600`: byte-identical before/after.
- Polling viewport, `crop=1100:1700:50:380`: byte-identical before/after.
- Plain page 1, `crop=850:380:300:520`: identical solid-glyph mask (`RGB < 64`).
  Glass shading differs only by one intensity level; text positions do not move.

Regions can be decoded with `ffmpeg -i <png> -vf crop=... -pix_fmt rgb24 -f rawvideo -`.
The frame checks cover the insertion interval too; paired screenshots alone are
not considered sufficient proof that no intermediate jump occurred.

## Shared core and integration

The pagination changes passed all 89 core tests and release Clippy with warnings
denied on the initial base. After integrating current main's independent removal
of audio recording, all **88 remaining core tests** pass and release Clippy again
passes. The two new HTTP pagination tests preserve reply/thought identities
through refresh and keep a single updated tool card when its older start loads.

Apple device, simulator and macOS Rust libraries were regenerated on current main.
The native macOS app builds successfully. The macOS ScrollView pager fixture also
passes, and the one-page-per-drag assertion was observed failing on baseline.
The current-main iOS integration rerun also passes **4/4**, covering initial
polling, three plain loads, three mixed loads and stable polling/live catch-up in
129.271 seconds. The full-suite source and tested conversation behavior are
unchanged. The direct Mac pager fixture and two additional iOS pager checks pass.

## Limits

These are fixture conversations, not the user's authenticated chat. The recording
and result bundle complement read-only display-link/layout instrumentation; this
is not a claim about all device/OS combinations. iOS 17/macOS 14 runtime execution
and automated mid-animation finger interruption are not claimed. No native
scroll-offset writer or timed correction loop is used.
