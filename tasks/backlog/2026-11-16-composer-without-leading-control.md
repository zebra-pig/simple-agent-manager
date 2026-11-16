# Composer render crash without attachments or leading control

## Problem

`ComposerInputLayout.placeSubviews` assumes three subviews. A Composer with
`files: nil`, no `leadingControl`, and `EmptyView` accessory can provide only two,
causing a LayoutSubviews subscript trap. Agent chat supplies `chat.files` and is
not affected by this fixture edge case.

## Context

Found while rendering the agent-send handoff on Xcode 27, both macOS and iOS
Simulator. The existing `ios/tests/composer-render.swift` also constructs this
configuration. Crash stack points to `ios/SAM/ProjectView.swift`,
`ComposerInputLayout.placeSubviews`, the third subview lookup.

## Acceptance criteria

- [ ] Preserve a layout slot when the optional attachment/leading control is absent.
- [ ] Render the existing composer fixtures with nil files on Mac and iOS without crashing.
