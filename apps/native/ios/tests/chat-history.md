# Earlier-history scroll regression (macOS)

Compile and run on a Mac from the repository root:

```sh
fixture_dir=$(mktemp -d)
swiftc -parse-as-library \
  apps/native/ios/SAM/ChatHistoryPager.swift \
  apps/native/ios/tests/chat-history-loading.swift \
  -o "$fixture_dir/history-loading"
"$fixture_dir/history-loading"
swiftc -parse-as-library \
  apps/native/ios/SAM/ChatHistoryAnchor.swift \
  apps/native/ios/tests/chat-history-position.swift \
  -o "$fixture_dir/history-position"
"$fixture_dir/history-position"
```

The loading fixture checks automatic entry, an in-flight guard, no chained
request when loading completes, error handling, and leaving/returning.
The position fixture uses the production anchor and geometry preferences with
variable-height lazy rows and SwiftUI's scroll binding. It prepends two pages
and asserts that the previously visible row stays within one point of its
saved position, including a partially clipped row on the second prepend.
These are offline fixtures; they do not access a live conversation.
