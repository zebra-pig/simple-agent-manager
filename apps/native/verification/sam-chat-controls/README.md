# SAM tab chat controls

The Apple SAM tab uses the same `Composer` and `ChatJumpButton` as agent chats.
Android uses its shared `Composer` and `LatestArrow`. SAM keeps voice transcription,
Stop, and pending-receipt Retry; it does not offer unsupported file attachments.

Verified on 2026-11-15:

- iOS Simulator and macOS `xcodebuild`, scheme SAM, signing disabled: pass.
- Android `:app:compileDebugKotlin`: pass.
- Android Robolectric `AssistantComposerTest` (5), `ChatRenderTest` (11),
  `ChatJumpTest` (1), `ChatHistoryTest` (3): 20 tests, zero failures or errors. Checks cover empty send,
  sending a draft, retry with a locked empty editor, stopping, and jump to latest.
- iPhone 17 Pro / iOS 27 simulator: inspected collapsed and expanded production
  composer plus jump control in an isolated fixture (screenshots alongside this file).
  This fixture has no backend conversation or microphone session.
- `ios/tests/composer-render.swift`: ten macOS layout smoke renders across
  empty/expanded/stop/retry/busy states and 375/1000pt widths. Offscreen AppKit
  bitmap capture omits glass buttons; use simulator screenshots for visual review.

Android test command (requires generated Kotlin core bindings and Android SDK):

```sh
./gradlew :app:testDebugUnitTest -x buildRustCore \
  --tests org.simpleagentmanager.app.AssistantComposerTest \
  --tests org.simpleagentmanager.app.ChatRenderTest \
  --tests org.simpleagentmanager.app.ChatJumpTest \
  --tests org.simpleagentmanager.app.ChatHistoryTest
```

The Rust core was unchanged. Validation reused compatible generated core bindings;
`-x buildRustCore` skips rebuilding Android native libraries for these UI-only tests.
