// Proposal 48: file paths in replies open in an in-app viewer at the right line.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/data/browse_api.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/file_browser_screen.dart';

import 'fakes.dart';
import 'harness.dart';

const _source = '''import { createHash } from 'node:crypto';

const store = new Set<string>();

export function hash(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export function issue(token: string): void {
  store.add(hash(token));
}

export function revoke(token: string): void {
  store.delete(hash(token));
}

/** Check a bearer token on every request. */
export function verify(token: string): boolean {
  return store.has(hash(token));
}

export function count(): number {
  return store.size;
}
''';

void main() {
  for (final size in [ShotSize.phone, ShotSize.desktop]) {
    testWidgets('file links (${size.dir})', (tester) async {
      await startShot(tester, size);
      final c = fakeController('s1', [
        {'id': 'm1', 'role': 'user', 'content': 'Where is the token check?', 'ts': '2026-10-10T09:00:00Z'},
        {
          'id': 'm2',
          'role': 'assistant',
          'content': 'The check is `verify` in `src/auth/login.ts:19`. The design is in docs/PLAN.md '
              'and the setup steps are in [the readme](./README.md).',
          'ts': '2026-10-10T09:00:05Z',
        },
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [chatControllerPoolProvider.overrideWithValue(FakePool({}))],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          home: ChatScreen(creds: creds, session: fakeSession('s1', 'Token check'), controller: c),
        ),
      ));
      await settle(tester);
      await shot(tester, 'file-links', size, 1, 'links-in-reply');

      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: FileViewerScreen(
          path: 'src/auth/login.ts',
          line: 19,
          load: () async => BrowseFile(path: 'src/auth/login.ts', size: _source.length, content: _source),
        ),
      ));
      await settle(tester);
      await shot(tester, 'file-links', size, 2, 'viewer-at-line');
      finishShot();
    });
  }
}
