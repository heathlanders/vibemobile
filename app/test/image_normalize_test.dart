import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/app_log.dart';
import 'package:vibemobile/features/chat/domain/image_normalize.dart';

/// A w×h 24-bit BMP — the shape `Pasteboard.image` hands back on Windows.
Uint8List bmp(int w, int h) {
  final row = (w * 3 + 3) & ~3;
  final size = 54 + row * h;
  final b = ByteData(size);
  b.setUint8(0, 0x42); // 'B'
  b.setUint8(1, 0x4d); // 'M'
  b.setUint32(2, size, Endian.little);
  b.setUint32(10, 54, Endian.little);
  b.setUint32(14, 40, Endian.little);
  b.setInt32(18, w, Endian.little);
  b.setInt32(22, h, Endian.little);
  b.setUint16(26, 1, Endian.little);
  b.setUint16(28, 24, Endian.little);
  for (var i = 54; i < size; i++) {
    b.setUint8(i, 0x80);
  }
  return b.buffer.asUint8List();
}

Future<Uint8List> png(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xff336699));
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

Future<(int, int)> dims(Uint8List bytes) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final d = await ui.ImageDescriptor.encoded(buf);
  final r = (d.width, d.height);
  d.dispose();
  buf.dispose();
  return r;
}

void main() {
  test('format allowlist mirrors the daemon sniff', () {
    expect(isUploadableFormat(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0])), isTrue);
    expect(isUploadableFormat(Uint8List.fromList([0xff, 0xd8, 0xff, 0])), isTrue);
    expect(isUploadableFormat(Uint8List.fromList('GIF89a'.codeUnits)), isTrue);
    expect(isUploadableFormat(Uint8List.fromList('RIFF\x00\x00\x00\x00WEBP'.codeUnits)), isTrue);
    expect(isUploadableFormat(bmp(2, 2)), isFalse);
  });

  testWidgets('a Windows-clipboard BMP is re-encoded as PNG', (tester) async {
    await tester.runAsync(() async {
      final out = await normalizeImage(bmp(4, 3));
      expect(isUploadableFormat(out), isTrue);
      expect(out.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      expect(await dims(out), (4, 3));
    });
  });

  testWidgets('an oversize image is downscaled to the long-edge cap', (tester) async {
    await tester.runAsync(() async {
      final out = await normalizeImage(await png(400, 200), maxEdge: 100);
      expect(await dims(out), (100, 50));
    });
  });

  testWidgets('an accepted image within the cap passes through untouched', (tester) async {
    await tester.runAsync(() async {
      final src = await png(40, 20);
      expect(identical(await normalizeImage(src, maxEdge: 100), src), isTrue);
    });
  });

  test('AppLog appends, rotates past the cap, and reads both generations', () async {
    final dir = await Directory.systemTemp.createTemp('applog');
    addTearDown(() => dir.delete(recursive: true));
    await AppLog.init(dir: dir);
    AppLog.error('first');
    expect(await AppLog.read(), contains(' E first'));

    File('${dir.path}/vibemobile.log').writeAsStringSync('x' * (AppLog.maxBytes + 1));
    AppLog.error('after-rotate');
    expect(File('${dir.path}/vibemobile.log.1').existsSync(), isTrue);
    final all = await AppLog.read();
    expect(all.indexOf('xxx') < all.indexOf('after-rotate'), isTrue);
  });
}
