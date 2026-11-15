# Project composer profile picker

Run on iPhone and macOS with a project containing at least two profiles. These are manual regression procedures, not executed device-test evidence.

1. Open the project with the keyboard closed. Confirm the profile capsule is visible immediately beside the attachment button, with send at the trailing edge.
2. Type a multi-line task. Confirm the input sits above the controls and the profile remains visible with the keyboard open.
3. Open the profile menu, choose a different profile and confirm the capsule updates. Close/reopen the keyboard and confirm the selected profile persists.
4. Submit the task and verify the new session uses the chosen profile.
5. Reopen the project. Open Edit from the menu for an editable profile; save and confirm the label updates. Create a profile from New profile and confirm it can be selected.
6. Try a long profile name, a narrow window and large accessibility text. Confirm the capsule truncates without displacing attach/send; VoiceOver should announce “Agent profile” and the selected name.
7. Open a project with no profiles. Confirm Project defaults and New profile remain accessible.
8. Attach a file, cancel/reopen the attachment picker and send text plus attachment. Confirm profile selection remains available throughout.
9. Open an existing chat and confirm its reply composer still uses its original inline input, attachment and send controls.

Build validation: use Xcode Cloud for both iOS and macOS. Native presentation and menu interaction require a simulator/device; Playwright does not render SwiftUI.
