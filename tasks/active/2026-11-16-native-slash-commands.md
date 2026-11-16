# Native slash commands

Implement a Liquid Glass command picker in the Apple task and reply composers;
verify on the Mac and deliver simulator screenshots. SAM task: 01M7HX5M2WASPNG4CQQQ1ZMCD7.
Output branch: sam/sam-bring-slash-commands-1zmcd7.

- [x] Save what SAM is and the user's current preference for working there in knowledge.
- [x] Read existing web command registry/cache contracts and native composer.
- [x] Add shared Rust cache discovery with registry fallback and custom-command overrides.
- [x] Add Apple glass autocomplete, draft insertion, keyboard navigation and dismissal.
- [x] Rust tests and Clippy pass.
- [x] Compile production iOS and macOS targets and cloud preparation script.
- [x] Verify production composer in isolated simulators; inspect and deliver screenshots.
- [ ] Review, push, open PR, reconcile checks/review and merge.

Scope: Apple UI with shared core command discovery. Cached agent commands and
well-known agent commands are completed as draft text; the existing explicit Send
flow delivers them. Web-only local clear/copy/export actions are not advertised.
No live-account task submission is performed by the verification fixtures.

Verification evidence is in apps/native/verification/slash-commands. The iOS
fixture caught an existing FocusState/UIKit bridge mismatch; the composer now
keeps explicit iOS responder state and retains keyboard focus during filtering.
All 84 core tests, strict Clippy, Apple builds and the cloud preparation script
pass. The headless macOS render omits compositor materials; actual simulator
screenshots are supplied for visual glass review. No live-account send performed.
