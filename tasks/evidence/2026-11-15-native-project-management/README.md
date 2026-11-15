# Native project management validation

Runtime source commit: `03fe12c0f1a2995488c25f217cbd5f232ac2dd02`.

- `cargo test --manifest-path apps/native/core/Cargo.toml`: 27 tests passed, including six project-management integration tests. Tests exercise cookie authentication, three provider creation payloads, partial GitHub access failures/retry, PATCH field preservation, denied mutations, invalid input, exact deletion confirmation and request serialization.
- `cargo clippy --manifest-path apps/native/core/Cargo.toml --all-targets -- -D warnings`: passed.
- `./gradlew assembleDebug --max-workers=2`: passed for arm64-v8a and x86_64.
- Xcode Cloud [run #24](https://appstoreconnect.apple.com/teams/035ee9cd-96f5-4913-8728-e1e24e283c5c/apps/6834915601/ci/builds/03259f32-5e9d-45f6-ae1a-96447ff6eb02): iOS archive, macOS archive and TestFlight internal testing all succeeded on the runtime source commit. The original manual branch start condition was restored after starting the run.
- Final Android `assembleDebug` after restoring Gradle files and removing the preview harness: passed in 10 seconds.
- `./gradlew updateDebugScreenshotTest -x buildRustCore --max-workers=2`: passed; three rendered previews.

## Android renders

The real `ProjectSettingsContent` composable was rendered with sample project data:

- [Creation, light, 375×812dp](android-create-light.png)
- [General settings and delete action, light, 375×1000dp](android-settings-light.png)
- [Compact settings, dark, 320×900dp](android-settings-dark-320.png)

All three images were opened and reviewed for hierarchy, clipping, overflow, readability and control spacing. No visual issue found; the compact description/help text wraps within its card. These are host renders, not device interaction or signed-in end-to-end tests. iOS/macOS use Xcode Cloud compilation; no iOS screenshot is claimed.

The temporary official Compose screenshot plugin was `com.android.compose.screenshot:0.0.1-alpha16`, with `android.experimental.enableScreenshotTest=true` in Gradle properties and Android experimental properties, plus screenshot-validation-api and Compose ui-tooling dependencies. The exact preview declarations are preserved in [preview-source.kt.txt](preview-source.kt.txt). Temporary Gradle edits and screenshot source sets were removed before the final debug build; no screenshot dependency ships in the app.

Local specialist review completed. Its findings about repository request races and retry-induced draft loss were addressed with loading guards, serialized core intents and a retry button restricted to initialization failures. Advanced web access/infrastructure/runtime/deployment settings remain on the web and are documented in the native README.
