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
