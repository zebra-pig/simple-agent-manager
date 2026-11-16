# Headless gallery OCR compatibility

Xcode Cloud builds 121 and 122 failed in the macOS gallery fixture after saving
`opened.png`, before printing the first recognized count. Vision setup/execution
threw `Foundation._GenericObjCError.nilError`. This prevented the native release,
even though the app's composer regression passed locally and on Cloud macOS.

The fixture now retries failed accurate OCR using a new accurate CPU-only request,
avoiding compute-stage discovery in that fallback. It still analyzes the same
production screenshot and applies every existing pagination, count, missing-image,
selection, swipe/momentum and zoom assertion. A second OCR failure still fails
the test; no assertion or test is skipped.

Local Mac verification on 2026-11-16:

- Normal production gallery fixture passed (`GALLERY_MAC_PAGINATION_SELECTION_NAVIGATION_PASS`).
- In an isolated test copy, injecting an error before compute-stage discovery
  forced the fallback for every capture. The same complete fixture passed.
- The fallback uses the deprecated but supported `VNRequest.usesCPUOnly` API only
  in this compatibility test path. Application runtime code is unchanged.

The exact Cloud error is reproducible across both builds; which Vision operation
threw is not established by the top-level log. The fallback catches errors from
both setup and execution and logs the first error explicitly.
