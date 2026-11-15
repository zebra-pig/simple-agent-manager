# Resolved request card verification

Captured the production `ChatView` and `RequestCard` with the real Rust core and
regenerated Swift bindings on the iPhone 18 Pro simulator, iOS 27.0 / Xcode 27.0.
The isolated fixture uses in-memory credentials and a localhost server only.

- [Pending](pending.png): the question and answer options remain visible. An older
  answered request recovered from notifications is hidden, including its wrapper.
- [Resolved and reopened](resolved.png): the conversation remains and both request
  cards are gone, with no empty glass card or notification heading left behind.

Test sequence: open the fixture with a pending transcript question; capture;
resolve it using the fixture endpoint; wait at least 15 seconds for the production
request poll; confirm the card disappears; terminate/reopen the fixture; capture
again and confirm it stays hidden. The final resolved capture is after reopening.
Reviewed both captures for card visibility, retained conversation/composer,
wrapping and empty card outlines. No remaining card layout issue was found.

The full 67-test Rust suite passes, including a new answered-question lifecycle
regression that checks successful response, refresh and refusal to answer again.
Existing tests also check pending delivery, expiry, fulfilled secrets and denied
approvals. Production macOS and iOS simulator builds pass. Android source follows
the same shared status predicate, but its build was not run: no Java runtime or
Android SDK was installed on the available hosts.

## Reproduce

Use the isolated fixture app setup from [project-list verification](../projects/README.md),
with its `SAMVisualFixture.swift` entry point and a regenerated Apple core.
Start `python3 fixture-server.py /absolute/path/to/port-file` from this directory.
Launch the fixture with `--chat --base=http://127.0.0.1:<port>`.
The HTTP server includes one pending transcript request and one answered request
available only through notifications.

After capturing the pending view, call
`curl http://127.0.0.1:<port>/fixture/resolve`, then wait at least 15 seconds for
the normal request polling cycle. The pending request must disappear. Reopen the
fixture and confirm that neither request reappears. Remove the fixture app and
stop the HTTP server when finished. This fixture never submits a real task or
accesses an account.
