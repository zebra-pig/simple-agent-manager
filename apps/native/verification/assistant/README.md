# SAM assistant verification

Android Compose host renders of the production `AssistantContent` and `MainTabs` composables,
using mock account-conversation state. These are layout evidence, not signed-in device captures.
The preserved fixture is `AssistantPreviews.kt`; it stays outside application source sets.

| Surface | Phone | Tablet |
| --- | --- | --- |
| Empty conversation and suggestions | [Phone](phone-welcome.png) | [Tablet](tablet-welcome.png) |
| Destructive action confirmation | [Phone](phone-confirmation.png) | [Tablet](tablet-confirmation.png) |
| Running turn and Stop | [Phone](phone-running.png) | — |
| Uncertain message and Retry | [Phone](phone-retry.png) | — |

Reviewed all six images for wrapping, clipping, contrast, composer visibility and the selected SAM
tab. The confirmation shows the exact request, consequence and destructive styling. Retry keeps
the held message visible and disables editing. Phone width is 393 dp; tablet width is 900 dp.

Reproduce with JDK 17, SDK 36, generated Kotlin bindings and the temporary screenshot plugin
configuration described in `../notifications/README.md`. Copy the fixture into the screenshot
source set, then run `updateDebugScreenshotTest -x buildRustCore`. The fixture calls the real Rust
Markdown and receipt-link helpers: set `JAVA_TOOL_OPTIONS=-Djna.library.path=<absolute core/target/debug>`
with a matching host `cargo build --lib`. Remove the temporary plugin/source set before the normal
`assembleDebug` build. No screenshot dependency ships with the application.

`core/tests/assistant.rs` exercises the exported view model through an authenticated scripted HTTP
server: settings gating, history and legacy pagination, live snapshots, durable retry across view-model
recreation, duplicate-send prevention, confirm/decline, uncertain-outcome reconciliation, stopping SAM,
marking work updates seen, sign-out isolation, voice multipart upload, and safe Markdown/link rendering.
Voice transcription returns draft text and does not create a turn.

The native client uses the web API unchanged. `AssistantViewModel::refresh_inner` polls the same
live snapshots carried by `/api/sam/turns` (every two seconds while a turn runs); it does not open the
web SSE stream. Settings and links open the signed-in deployment's web UI; project chat destinations
open natively. Microphone permission and physical-device audio capture require device verification.
