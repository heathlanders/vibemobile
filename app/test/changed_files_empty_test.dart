import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/data/file_edits_api.dart';
import 'package:vibemobile/features/chat/domain/file_edits.dart';
import 'package:vibemobile/features/chat/presentation/changed_files_sheet.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

class _EmptyApi extends FileEditsApi {
  _EmptyApi() : super(Dio());
  @override
  Future<List<ChangedFile>> changedFiles(String sessionId) async => const [];
}

void main() {
  testWidgets('with no tracked edits the list still offers Commit… (shell changes are real changes)', (t) async {
    const session = Session(id: 's1', projectId: 'p', kind: 'claude', status: 'live', createdAt: 't');
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChangedFilesList(api: _EmptyApi(), creds: const Creds('http://x', 't'), session: session),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('No files changed'), findsOneWidget);
    expect(find.text('Commit…'), findsOneWidget);
  });
}
