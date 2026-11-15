# Chat previews

Rendered with Android's official Compose screenshot plugin (`0.0.1-alpha16`) from
`src/screenshotTest/kotlin/org/simpleagentmanager/app/ChatPreviews.kt`.
These are native Compose host renders with fixture data, without a live account.

| Preview | Baseline |
| --- | --- |
| Phone | [Light](reference/org/simpleagentmanager/app/ChatPreviewsKt/PhoneChat_Phone_75916920_0.png) |
| Dark mode | [Dark](reference/org/simpleagentmanager/app/ChatPreviewsKt/DarkChat_Dark_36e81ac2_0.png) |
| Tablet | [1280 dp wide](reference/org/simpleagentmanager/app/ChatPreviewsKt/TabletChat_Tablet_f32bdb34_0.png) |
| Large text | [150% font scale](<reference/org/simpleagentmanager/app/ChatPreviewsKt/LargeTextChat_Large text_2184f8a3_0.png>) |
| Latest arrow | [Neutral control](<reference/org/simpleagentmanager/app/ChatPreviewsKt/LatestArrowPreview_Latest arrow_3e070f92_0.png>) |

From `apps/native/android`, regenerate with `./gradlew updateDebugScreenshotTest` and
compare with `./gradlew validateDebugScreenshotTest`. Robolectric's `testDebugUnitTest`
checks interaction, including expanding activity and using the history arrow.

The composer still uses its existing layout; matching the user's collapsed/expanded
references is pending recovery of the images lost during the workspace restart.
