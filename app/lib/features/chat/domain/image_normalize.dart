import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Claude's long-edge cap; the picker path downscales to the same value.
const maxImageEdge = 1568;

/// True for the formats the daemon's magic-byte sniff accepts (attachments.ts
/// `sniffMediaType`): png, jpeg, webp, gif.
bool isUploadableFormat(Uint8List b) {
  bool ascii(int at, String s) =>
      b.length >= at + s.length && String.fromCharCodes(b.sublist(at, at + s.length)) == s;
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) return true;
  if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return true;
  if (ascii(0, 'RIFF') && ascii(8, 'WEBP')) return true;
  return ascii(0, 'GIF87a') || ascii(0, 'GIF89a');
}

/// Make raw image bytes uploadable: an accepted format within [maxEdge] passes
/// through untouched; anything else (e.g. the BMP that `Pasteboard.image`
/// returns on Windows, or a full-res screenshot) is decoded by the engine,
/// downscaled to ≤[maxEdge] on the long edge, and re-encoded as PNG.
/// Throws if the engine can't decode the bytes at all.
Future<Uint8List> normalizeImage(Uint8List bytes, {int maxEdge = maxImageEdge}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  try {
    final w = desc.width, h = desc.height;
    final long = math.max(w, h);
    if (long <= maxEdge && isUploadableFormat(bytes)) return bytes;
    final scale = long > maxEdge ? maxEdge / long : 1.0;
    final codec = await desc.instantiateCodec(
      targetWidth: math.max(1, (w * scale).round()),
      targetHeight: math.max(1, (h * scale).round()),
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return png!.buffer.asUint8List();
  } finally {
    desc.dispose();
    buffer.dispose();
  }
}
