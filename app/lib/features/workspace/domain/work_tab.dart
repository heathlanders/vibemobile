import '../../editor/presentation/editor_controller.dart';
import '../../sessions/domain/session.dart';

/// A workspace tab (ADR 0015, proposal 60): a session (chat or terminal) or an open file. Its [id]
/// is the session id for sessions, so ids stored before file tabs existed still load; a file tab's id
/// is `file:<scope>|<path>`.
class WorkTab {
  WorkTab.session(Session s)
      : session = s,
        file = null,
        id = s.id;
  WorkTab.file(EditorTarget t)
      : session = null,
        file = t,
        id = fileTabId(t.api.scope, t.path);

  final Session? session;
  final EditorTarget? file;
  final String id;

  bool get isFile => file != null;
}

const _filePrefix = 'file:';

String fileTabId(String scope, String path) => '$_filePrefix$scope|$path';

/// The scope (`projects/<id>` / `sessions/<id>`) and path of a [fileTabId], else null.
(String, String)? parseFileTabId(String id) {
  if (!id.startsWith(_filePrefix)) return null;
  final bar = id.indexOf('|');
  if (bar < 0) return null;
  return (id.substring(_filePrefix.length, bar), id.substring(bar + 1));
}
