import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/files/presentation/upload_to_root.dart';

import 'project_files_test.dart' show UploadFake, src;

void main() {
  /// Pumps an empty screen and returns a context that can show snackbars and dialogs.
  Future<BuildContext> host(WidgetTester t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    return ctx;
  }

  testWidgets('uploads every file into the root and reports it', (t) async {
    final api = UploadFake()..existing = 0;
    final done = await uploadToRoot(await host(t), api, [src('a.pdf'), src('b.zip')]);
    await t.pump();
    expect(api.calls, [('', 'a.pdf', false), ('', 'b.zip', false)]);
    expect(done, ['a.pdf', 'b.zip']);
    expect(find.text('Uploaded 2 files to project root'), findsOneWidget);
  });

  testWidgets('a 409 asks to overwrite, then retries with overwrite true', (t) async {
    final api = UploadFake();
    final f = uploadToRoot(await host(t), api, [src('a.pdf')]);
    await t.pumpAndSettle();
    expect(find.text('a.pdf already exists. Overwrite?'), findsOneWidget);
    await t.tap(find.text('Overwrite'));
    await t.pumpAndSettle();
    expect(await f, ['a.pdf']);
    expect(api.calls, [('', 'a.pdf', false), ('', 'a.pdf', true)]);
  });

  testWidgets('Skip leaves the existing file and uploads nothing', (t) async {
    final api = UploadFake();
    final f = uploadToRoot(await host(t), api, [src('a.pdf')]);
    await t.pumpAndSettle();
    await t.tap(find.text('Skip'));
    await t.pumpAndSettle();
    expect(await f, isEmpty);
    expect(api.calls, [('', 'a.pdf', false)]);
  });
}
