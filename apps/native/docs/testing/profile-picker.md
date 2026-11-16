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

## Chat tab bar

Open a conversation from Projects, from Notifications, and from a push notification. Confirm the app tab bar is hidden while chat is visible, with the reply composer above the system safe area. Go back and confirm tabs return on the parent screen. Repeat with keyboard open/closed and an interactive back gesture (including cancelling the gesture). On macOS confirm navigation and chat still build; there is no iOS tab-bar modifier on that platform. Android already limits its bottom tabs to the Projects and Notifications roots. These checks have not been executed on a device in this workspace.

## Project tab bar

Open a project from the Projects root. Confirm the app tab bar is hidden with the keyboard closed and open. Enter chat and go back to the project: tabs should remain hidden. Go back to the Projects root: tabs should return. Check an interactive back gesture and cancel it; the project should keep tabs hidden. Repeat with an empty project and with the profile editor sheet open/closed. These are manual device procedures, not executed checks. Android already limits bottom tabs to root routes.
