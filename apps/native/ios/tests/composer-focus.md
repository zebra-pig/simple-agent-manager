# Project composer keyboard regression

`ProjectView` opts into `Composer.dismissFocusOnSend`. Send clears the focus
before starting submission, and the editor stays disabled during submission.
The iOS `ComposerTextInput` resigns first responder when focus is cleared.

`composer-focus-ios.swift` is an offline simulator app entry point. In an
isolated copy of `apps/native/ios` with generated bindings available, replace
`SAM/SAMApp.swift` with this fixture. Build the SAM scheme for an iOS simulator
with `PRODUCT_BUNDLE_IDENTIFIER=dev.zebrapig.validation.keyboard` and
`CODE_SIGNING_ALLOWED=NO`, then install and launch it on an isolated simulator.
Read `Documents/focus-result.txt` in its data container; it must start with PASS.
The fixture uses the production editor, focuses it, clears its focus, pushes and
pops navigation, verifies it stays unfocused, and verifies explicit refocus works.
It makes no network requests and does not submit a real agent task.

Also manually check the project flow: type a task, tap Send, wait for its agent
view, then go back. The keyboard should close on Send and stay closed on return.
