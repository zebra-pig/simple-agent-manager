# Floating errors (Apple)

Current operation errors use `floatingErrors` on the screen rather than red text
inside its list, transcript or composer. The badge overlays the top safe area,
uses system material and Dynamic Type, has a 44-point dismiss control, announces
new errors, and disables movement when Reduce Motion is enabled. Errors remain
until dismissed or resolved; resolving an error allows the same message to appear
again on a later failure. Identical errors are deduplicated within a screen.

Screens pass their own error state directly, so chat errors appear even when the
user is reading an older part of the transcript. Nested request cards and attachment
controls report errors through `ErrorNotice`; screen hosts consume those reports
without forwarding them to another host. Sheets own their host so their errors
appear above the sheet. Retry actions remain in their original context. Historical
agent/task failure details remain in the relevant transcript or task card.

Validation on the remote Mac with Xcode 27:

- Typecheck the production Swift sources for iOS 17 and macOS 14 using the generated
  shared-core bindings. Existing macOS Push delegate warnings are unrelated.
- Run `bash apps/native/ios/tests/render-steering-ios.sh` to build and launch the
  production chat in an isolated iPhone simulator, including interrupt failure.
  The `chat-error.png` capture verifies the floating error above the conversation.
- Run `bash apps/native/ios/tests/error-badges.sh` to exercise nested preference
  reporting and sheet ownership using the production badge components.

Android presentation is unchanged by this Apple UI change.
