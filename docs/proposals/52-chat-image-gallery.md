# 52 — Chat image gallery

**Status:** shipped 2026-10-10

From the inbox: "if there are multiple images it should be a slideshow gallery; clicking off it or
hitting Escape should close the image, right now the only way is the X button."

Before this, the viewer (`ImageViewerScreen`, proposal 33) only swiped through the images of the
tapped message. A mouse can't swipe a `PageView`, so on desktop there was no way to move between
images, and the only way to close it was the back button.

- **Whole-chat gallery:** tapping any chat image opens a slideshow over every image in the
  conversation, in chat order, starting at the tapped one. That covers user uploads, tool-result
  images and project images the reply mentions. The chat screen provides the list once through
  a `ChatGallery` inherited widget. A thumbnail outside a chat keeps its own list.
- **Navigation:** left/right overlay arrows (mouse and touch), the Left/Right keys, swiping on
  touch, and a bottom thumbnail strip that highlights the current image and jumps on tap. The
  title still reads `i / n`.
- **Closing:** Escape, a tap or click on the backdrop outside the image, or the back button.
  Pinch-zoom and pan still work.

Client only; no daemon change.
