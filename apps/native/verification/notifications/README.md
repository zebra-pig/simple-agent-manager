# Actionable notification verification

These are Android Compose host renders of the production `RequestContent` and `MainTabs`
composables with mock server state. They are layout evidence, not screenshots of a signed-in
live device. Apple compilation is verified separately with Xcode Cloud.

| Surface | Phone | Tablet |
| --- | --- | --- |
| Inbox, option and text answers, tab navigation | [Phone](phone-inbox.png) | [Tablet](tablet-inbox.png) |
| Secret replacement and Operations approvals (also used in chat) | [Phone](phone-requests.png) | [Tablet](tablet-requests.png) |

Reviewed all four images for clipping, wrapping, contrast, readable controls and masked values.
The long option wraps; answer input fills the available width; the secret value stays masked;
save is disabled without replacement consent; destructive approval has an explicit warning.
Phone form renders are 393 dp wide, tablet renders 900 dp wide. The requests image uses a taller
canvas to show both full forms; the real inbox uses a scrolling `LazyColumn`.

`NotificationPreviews.kt` is the preserved fixture. It is outside the Android source sets so no
preview plugin or test-only dependency ships with the app. To reproduce, use a temporary copy
of `apps/native/android`, generate Kotlin bindings, copy the fixture into
`app/src/screenshotTest/kotlin/org/simpleagentmanager/app/`, and temporarily configure:

- `com.android.compose.screenshot` plugin `0.0.1-alpha16` on the app module.
- `android.experimental.enableScreenshotTest=true` in Gradle properties and the Android
  `experimentalProperties` map.
- `screenshotTestImplementation("com.android.tools.screenshot:screenshot-validation-api:0.0.1-alpha16")`
  and `screenshotTestImplementation("androidx.compose.ui:ui-tooling")`.

Run `./gradlew updateDebugScreenshotTest -x buildRustCore` with JDK 17 and Android SDK 36.
Reference images appear under `app/src/screenshotTestDebug/reference`.
The normal application build remains `./gradlew assembleDebug`.

`core/tests/notifications.rs` drives the exported view models against an authenticated scripted
HTTP server. It checks cursor pagination including read requests; option answers and pending
delivery; fresh and replacement secrets; conflict/retry and decline; expired/forbidden requests;
Operations decisions with project gating and delivery failure; compact tool metadata parsing;
and session-scoped requests outside the current chat page. Existing sign-in, provisioning,
profile, attachment and push registration tests also run with `cargo test`.

The API routes are unchanged. Live device answer delivery and push-tap navigation still require
a signed-in device; the automated wire tests exercise the same REST paths and payloads.
