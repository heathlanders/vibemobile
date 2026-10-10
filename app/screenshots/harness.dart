// Shared harness for the workflow screenshots (proposal 50). Fonts, window
// sizes, platform overrides and the golden helper live here.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Window sizes in logical pixels. Desktop sizes run with the Windows platform
/// override so `DesktopShell` (and its compact mode) is what gets drawn.
enum ShotSize {
  phone('phone', 412, 915, 2, TargetPlatform.android),
  desktop('desktop', 1440, 900, 1, TargetPlatform.windows),
  desktopCompact('desktop-compact', 800, 700, 1, TargetPlatform.windows);

  const ShotSize(this.dir, this.width, this.height, this.ratio, this.platform);
  final String dir;
  final double width, height, ratio;
  final TargetPlatform platform;
}

bool _fontsLoaded = false;

/// The Flutter SDK dir: FLUTTER_ROOT, else `~/flutter`, else next to the running flutter_tester.
String _flutterRoot() {
  final env = Platform.environment;
  final candidates = [
    env['FLUTTER_ROOT'],
    if (env['HOME'] != null) '${env['HOME']}/flutter',
    // .../bin/cache/artifacts/engine/<platform>/flutter_tester
    File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path,
  ];
  for (final c in candidates.nonNulls) {
    if (Directory('$c/bin/cache/artifacts/material_fonts').existsSync()) return c;
  }
  throw StateError('Flutter SDK not found; set FLUTTER_ROOT');
}

Future<void> _load(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

/// Load Roboto, MaterialIcons and the bundled JetBrainsMono once per test run so
/// text and icons render as glyphs instead of test-font boxes.
Future<void> loadFonts() async {
  if (_fontsLoaded) return;
  final fonts = '${_flutterRoot()}/bin/cache/artifacts/material_fonts';
  final roboto = ['Regular', 'Medium', 'Bold'].map((w) => '$fonts/Roboto-$w.ttf').toList();
  await _load('Roboto', roboto);
  // Windows' default text theme asks for Segoe UI, which the box does not have.
  await _load('Segoe UI', roboto);
  await _load('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
  // screenshots/ sits next to fonts/ under app/ (tests run with cwd = app/).
  await _load('JetBrainsMono', ['fonts/JetBrainsMono-Regular.ttf', 'fonts/JetBrainsMono-Bold.ttf']);
  _fontsLoaded = true;
}

/// Size the test window and pick the platform. Call [finishShot] as the last
/// step of the test body: the binding checks the platform override before
/// tearDowns run.
Future<void> startShot(WidgetTester tester, ShotSize size) async {
  await loadFonts();
  tester.view.devicePixelRatio = size.ratio;
  tester.view.physicalSize = Size(size.width * size.ratio, size.height * size.ratio);
  addTearDown(tester.view.reset);
  debugDefaultTargetPlatformOverride = size.platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

void finishShot() => debugDefaultTargetPlatformOverride = null;

/// Compare/update `docs/screenshots/<workflow>/<size>/NN-<name>.png`. Golden
/// paths are relative to the test file (`app/screenshots/`), so `../../docs`
/// is the repo's docs dir.
Future<void> shot(WidgetTester tester, String workflow, ShotSize size, int step, String name, {Finder? root}) {
  final nn = '$step'.padLeft(2, '0');
  return expectLater(
    root ?? find.byType(WidgetsApp).first,
    matchesGoldenFile('../../docs/screenshots/$workflow/${size.dir}/$nn-$name.png'),
  );
}

/// Let animations finish. Pumps fixed durations (never pumpAndSettle alone),
/// so spinners and carets cannot hang the run.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}
