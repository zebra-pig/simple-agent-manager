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
- [x] Run keyboard and existing scroll regressions on phone and tablet.
- [x] Review screenshot evidence and run specialist/completion review.
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

Native correctness/task-completion review found no implementation issues.
Full iPhone 18 Pro suite: 21 passed, no failures/skips. A focused rerun explicitly
selects dark appearance with XXXL text (1 passed), visually confirmed after the
original appearance launch argument proved ineffective. The iPad Pro 13-inch
(M5) focused keyboard check passed: message and composer both rise 383 pt and
retain their 52 pt gap. All runs use iOS 27.0 and Xcode 27.0.

The tablet run first exposed an instrumentation problem: the read-only probe
only discovered transcripts with content taller than their full viewport. It now
identifies the production transcript by type, including fitting content; the
rerun delivered geometry samples and passed. No production change was needed.

Before/after phone, true dark/XXXL and iPad screenshots reviewed. Evidence stays
in Mac scratch space and the project library under `/native/keyboard-x46pvx`.
The full suite ran source ac2aa9688; subsequent changes affect only fixture
appearance/probe selection and are covered by the focused runs. Production code
is identical across all passing runs. Physical devices/older iOS not exercised.

## Merge gate maintenance

CI's secret scan was blocked by an unrelated historical fixture exception that
expired on November 27. Removed that obsolete exception rather than extending
it. No new allowlist entries, scanner behavior, or workflows changed. Local
checksum-verified Gitleaks 8.30.1 current-tree and PR-range checks pass with zero
new findings; read-only review confirms only that single expired group changed.
This is a blocking adjacent metadata cleanup; native source and validation stay
unchanged.

Existing secret-scan policy suite: 13 tests passed. Markdown/JSON formatting and
`git diff --check` pass.
