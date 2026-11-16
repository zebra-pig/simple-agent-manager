# Steering UI review

Captured with `xcrun simctl io ... screenshot` on the Tailscale Mac, using an
isolated iPhone 17 Pro simulator running iOS 27. These are the production
`ChatView`, composer, steering controls, timeline and generated Rust bindings,
with an offline API supplying sample messages. No live account or task is used.

- `steer.png`: default Steer now mode and confirmed Steered delivery label.
- `queue.png`: Queue next selection, explanation and composer placeholder.
- `interrupting.png`: cancellation in flight, disabled control and spinner.
- `error.png`: failed cancellation remains visible with Interrupt available to retry.
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
