# Uploaded image preview recovery

Attachment preview reads prefer the owner-scoped original-upload endpoint. If it
returns 404 or 410 (removed staging object or an older server without that route),
read the delivered copy through the current session's existing authenticated
`files/raw` route at `/workspaces/.private/<uploadId>/<filename>`.

The server retains its existing workspace-owner/shared-reader confinement rules.
Do not fallback on 401, 403, rate limits or server errors. Both reads keep the
20 MiB limit and credential checks. Only transcript/outbox references are allowed;
attachment path components cannot contain traversal, separators or controls.
Library files retain their existing download path.

This restores copies that still exist in an accessible workspace without a new
backend deployment. If both original storage and the workspace copy are gone,
there are no image bytes to recover; no permanent-retention guarantee is added.
The user's actual server/account was not used for validation.

Validation on the macOS build host:

- Full Rust suite passes. Six uploaded-preview regression tests cover originals,
  fallback and encoding, auth denials/sign-out, missing/unavailable copies, size
  limits, unreferenced IDs and malicious metadata paths.
- Real generated Swift -> Rust -> local HTTP -> ImageIO integration passes:
  UPLOADED_PREVIEW_SWIFT_RUST_IMAGEIO_PASS. Original returns 404; the workspace
  route returns a generated mock PNG; bytes match and decode successfully.
- Rust core and UniFFI rebuilt; full unsigned iOS Simulator and macOS builds pass.
- Xcode Cloud's existing macOS post-clone hook also runs the integration fixture.

To reproduce the native integration after `apps/native/scripts/build-ios.sh`:

```sh
native_generated=apps/native/ios/Generated
xcrun --sdk macosx swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  -I "$native_generated/SamCore.xcframework/macos-arm64/Headers" \
  "$native_generated/SamCore.swift" apps/native/ios/tests/uploaded-preview-macos.swift \
  -L "$native_generated/SamCore.xcframework/macos-arm64" \
  -lsam_core -framework Security -framework SystemConfiguration \
  -o /tmp/sam-uploaded-preview-test
python3 apps/native/ios/tests/uploaded-preview-server.py /tmp/sam-uploaded-preview-test
```
