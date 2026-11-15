# Chat image and file previews

Compose host rendering of the production `DocumentCardContent` and
`DocumentGalleryContent` with mock image, PDF, deleted-file and network-error states.
These are component previews, not screenshots from a device. The gallery fixture uses
a solid image to make its boundaries visible.

| Surface | 375dp phone | 1280dp wide window |
| --- | --- | --- |
| Image and file cards | [Mobile](cards-mobile.png) | [Wide](cards-wide.png) |
| Gallery | [Mobile](gallery-mobile.png) | [Wide](gallery-wide.png) |

Inspected for readability, clipping, overflow and control placement. No visual issues
found. These Android renders do not verify macOS appearance, OS viewer launching or
pinch gestures. Apple builds are validated separately through Xcode Cloud.
