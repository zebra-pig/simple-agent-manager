# Investigate the native notification-response crash reported by TestFlight

## Problem

While investigating the iPad first-task send freeze, App Store Connect's newest
available SAM crash report was a separate iPhone crash on November 18, build 146.
Its exception backtrace includes UIKit's
`_performBlockAfterCATransactionCommitSynchronizes` and
`_updateSnapshotAndStateRestorationWithAction`, followed by the synthesized
completion of `PushDelegate.userNotificationCenter(_:didReceive:)` on thread 7.
This is separate from the directly reproduced iPad composer responder-graph hang.

## Context

`apps/native/ios/SAM/Push.swift` routes notification taps through an async delegate
method, with `MainActor.run` around the route assignment. The file is unchanged
since `644d561e7`. The crash log does not establish that route assignment is the
cause; investigate the async delegate completion's actor/thread and UIKit's
state-restoration requirement before changing it.

The report was read through `betaFeedbackCrashSubmissions/.../crashLog` during
PR #102. The API exposed no report dated November 23 and no screenshot feedback.
Keep raw crash logs in scratch space or the project Library, outside git.

## Acceptance criteria

- [ ] Retrieve the ASC build-146 notification-response crash and identify the asserted requirement.
- [ ] Reproduce notification-tap/background state-restoration behavior on a device or simulator, with a behavior regression that reaches the delegate callback.
- [ ] Fix the confirmed cause and verify routing still opens the correct project/session.
- [ ] Validate with `apps/native/scripts/test.sh`; keep tests out of Xcode Cloud.
