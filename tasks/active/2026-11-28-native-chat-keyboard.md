# Keep chat aligned with the keyboard composer

Opening the reply input must lift the latest chat message together with the
composer, without pushing it beyond the top screen edge.

## Preflight

- Class: ui-change. iOS only; no API, Rust, Android, or workflow changes planned.
- Path: ChatView's safeAreaInset/GeometryReader → ChatTranscript.updateUIView →
  ChatTranscriptView.setInsets/applyInsets → layoutSubviews/pinToBottom.
- Investigate keyboard safe-area overlap and UIKit's automatic adjustment before
  choosing a fix. Preserve full-bleed scroll edges and older-history anchoring.
- Existing XCTest chat-scroll harness runs actual production views, Rust/HTTP
  models, system keyboard and measured on-screen frames. Mac access verified.
- Constitution: smallest existing-layout correction, no dependency or config
  additions; verify the actual gesture and changed layout with regression tests.
- Documentation: update TESTING.md for keyboard regression coverage; no public
  contract or setup changes.

## Checklist

- [x] Inspect user screenshot and trace existing iOS layout.
- [x] Add behavior test using a real keyboard tap and message/composer geometry.
- [x] Reproduce failure on unchanged production code.
- [x] Apply smallest layout correction.
- [ ] Run keyboard and existing scroll regressions on phone and tablet.
- [ ] Review screenshot evidence and run specialist/completion review.
- [ ] Open PR, address review and checks, and merge.

## Reproduction and correction

The baseline real-keyboard test failed: latest y=676→54 (622 pt rise), composer
y=750→456 (294 pt rise), a 328 pt excess equal to the keyboard height. The
transcript viewport was 546 pt high with a 442 pt bottom inset.

After changing only the transcript safe-area regions from `.container` to `.all`,
the test passed: latest y=676→382 and composer y=750→456, both rising 294 pt.
The viewport stays 874 pt high, and the bottom inset remains 442 pt. The outer
GeometryReader still observes the bars/keyboard; the composer still avoids it.
The baseline screenshot shows the same blank chat area as the user attachment.

Native correctness/task-completion review found no implementation issues. Full
phone scroll regressions (including dark/large text) and focused iPad keyboard
coverage are running. Evidence stays in Mac scratch space and the project library.
