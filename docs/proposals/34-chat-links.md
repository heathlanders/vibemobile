# 34 — Chat links

**Status:** implemented

URLs in chat messages (user, assistant, error) render as tappable links.

- `splitLinks` (`app/lib/features/chat/domain/link_spans.dart`): finds `http(s)://` URLs; trims trailing punctuation; keeps `)` only when balanced. Other schemes are never linkified.
- `LinkifiedText` (`chat/presentation/linkified_text.dart`): `Text.rich` with `TapGestureRecognizer` per link → `launchUrl(..., LaunchMode.externalApplication)`. Never an in-app webview. Optional `trailing` span carries the streaming cursor.
- Wired in `_align()` and the user-with-images bubble in `chat_screen.dart`.
- Android: `https` VIEW intent in manifest `<queries>` (package visibility).

Out of scope: markdown `[text](url)`, links in tool output.
