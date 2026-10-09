import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/image_paths.dart';

void main() {
  test('finds bare, backticked, quoted and absolute paths', () {
    expect(
      extractImagePaths('Saved to `out/chart.png`. Also "./img/x.jpg" and /home/u/p/shot.JPEG, then (img/c.webp).'),
      ['out/chart.png', './img/x.jpg', '/home/u/p/shot.JPEG', 'img/c.webp'],
    );
  });

  test('path at start / end of text, trailing punctuation', () {
    expect(extractImagePaths('a.gif is done'), ['a.gif']);
    expect(extractImagePaths('see docs/screens/home.png.'), ['docs/screens/home.png']);
    expect(extractImagePaths('see docs/screens/home.png!'), ['docs/screens/home.png']);
  });

  test('skips URLs, non-images, svg and prefix-only matches', () {
    expect(extractImagePaths('https://x.io/a.png and notes.md and logo.svg and file.pngx'), isEmpty);
  });

  test('dedupes and caps', () {
    expect(extractImagePaths('a.png a.png b.png'), ['a.png', 'b.png']);
    final many = List.generate(10, (i) => 'f$i.png').join(' ');
    expect(extractImagePaths(many).length, 6);
  });
}
