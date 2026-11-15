# Android JNA 16 KB page alignment

## Problem

Android lint for the native app reports `Aligned16KB` warnings on x86_64 `libjnidispatch.so`
from the existing JNA 5.14.0 dependency. That binary may not load on devices requiring 16 KB pages.

## Context

Found while running `apps/native/android/gradlew lintDebug` for the global SAM assistant tab.
The warning comes from the pre-existing dependency, not the Rust library built with NDK 28.

## Acceptance criteria

- [ ] Select a compatible JNA build with 16 KB aligned native binaries.
- [ ] Verify UniFFI callbacks, Rust object cleanup and both Android ABIs still work.
- [ ] `lintDebug` no longer reports `Aligned16KB` for JNA.
