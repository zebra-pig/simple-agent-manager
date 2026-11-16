# Steering UI review

Captured with `xcrun simctl io ... screenshot` on the Tailscale Mac, using an
isolated iPhone 17 Pro simulator running iOS 27. These are the production
`ChatView`, composer, steering controls, timeline and generated Rust bindings,
with an offline API supplying sample messages. No live account or task is used.

- `steer.png`: default Steer now menu below the text, monochrome Stop, and confirmed Steered delivery label.
- `queue.png`: Queue next menu selection and composer placeholder.
- `draft.png`: a filled draft exposes Send in the same position as Stop.
- `interrupting.png`: cancellation in flight, spinner in the same action position.
- `error.png`: failed cancellation remains visible with the icon-only Stop available to retry.
- `unsupported.png`: runtime reports steering unsupported; Queue next is locked.

Reproduce from the repository root on the Mac after building Apple bindings:

```sh
bash apps/native/ios/tests/render-steering-ios.sh
```

The script removes its simulator and stops the offline API when finished.
New captures are in `steering-simulator/screenshots/` (use an isolated checkout).

Validation: 82 Rust tests pass; Clippy passes with warnings denied; the iOS and
macOS app schemes build; the macOS CI post-clone fixture/build script passes;
Android app/test Kotlin compilation and the 4 selected chat test classes pass.

The Apple composer uses the same accessory row as the agent starter: attachment,
delivery menu, then the icon-only action. No separate agent-working row or delivery
hint row remains. iOS/macOS builds and the macOS CI post-clone checks were rerun
after this UI revision; shared Rust and Android code did not change in this revision.
