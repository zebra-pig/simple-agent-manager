# Attachment picker regression check

Run on an iPhone or iPad with a development or TestFlight build. The shared
composer is used both on a project (new task) and in a chat (follow-up); check
both. Repeat with the keyboard visible and hidden.

1. Tap Attach files, then Choose Files. The system Files browser must appear.
2. Cancel. Reopen Files and select a small text file. Its attachment chip must
   appear and upload, then become ready to send.
3. Tap Attach files, then Photo Library. The system photo picker must appear.
4. Cancel. Reopen Photos and select a photo. Its attachment chip must appear
   and upload, then become ready to send.
5. Reopen Photos and select the same photo again, then select several photos
   and a video. Each selection must be accepted and the picker must dismiss.
6. Remove all chips and repeat Files → cancel → Photos → cancel → Files.
   Each dialog must open every time, with no stuck or overlapping presentation.
7. Send a file-only message and verify its attachment reaches the conversation.

Also check Files and Photos on macOS, since the composer is shared. These are
interactive checks: a source-text assertion cannot verify system presentation.

## Paste into the input

Check both project task creation and chat follow-ups on iOS. Use the input's
long-press Paste action and, with a hardware keyboard, Command-V.

1. Copy a PDF in Files, focus the input, and paste. Exactly one attachment chip
   must appear with the correct name and upload to ready; no file URL should
   be inserted as message text.
2. Copy multiple files in Files, including a text file and an arbitrary binary
   file. Paste and confirm that every file appears once and can be sent.
3. Copy an image from Photos and a screenshot from its Copy action. Paste each
   into the input; both must upload as images, including clipboard providers
   that supply only data rather than a file representation.
4. Copy ordinary text and a web URL. Paste into the middle of an existing draft
   and over a selection. Text must be inserted/replaced at the cursor without
   an attachment chip. Check typing, undo, dictation and IME composition too.
5. Paste mixed file/text items. Files must attach and text must remain editable.
6. Verify empty-input placeholder, Dynamic Type, one-to-six-line growth,
   scrolling a longer draft, keyboard dismissal, profile accessory visibility,
   and clearing the draft after sending.
7. Confirm that simply focusing the input does not read the clipboard or show a
   paste-permission prompt. Remove pasted attachments and repeat the paste.

On macOS, repeat file/image Command-V and normal text insertion/selection checks.
