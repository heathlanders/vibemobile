import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/app_log.dart';
import '../../../core/providers.dart';
import '../data/update_api.dart';
import '../data/update_installer.dart';
import '../domain/update_info.dart';

class UpdateState {
  const UpdateState({this.info, this.dismissedBuild = 0, this.progress, this.error, this.manualWindows = false});
  final UpdateInfo? info; // non-null only when an update is available
  final int dismissedBuild;
  final double? progress; // non-null while downloading/installing
  final String? error;
  final bool manualWindows; // Windows install dir not writable

  bool get visible => info != null && info!.build > dismissedBuild;

  UpdateState copyWith({
    UpdateInfo? info,
    int? dismissedBuild,
    Object? progress = _keep,
    Object? error = _keep,
    bool? manualWindows,
  }) =>
      UpdateState(
        info: info ?? this.info,
        dismissedBuild: dismissedBuild ?? this.dismissedBuild,
        progress: identical(progress, _keep) ? this.progress : progress as double?,
        error: identical(error, _keep) ? this.error : error as String?,
        manualWindows: manualWindows ?? this.manualWindows,
      );
}

const _keep = Object();

final updateApiProvider = Provider<UpdateApi>((ref) => UpdateApi());

/// "1.0.19 (build 20)" for the Settings footer.
final appVersionProvider = FutureProvider<String>((ref) async {
  final p = await PackageInfo.fromPlatform();
  return '${p.version} (build ${p.buildNumber})';
});

final updateProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

class UpdateController extends Notifier<UpdateState> {
  static const _every = Duration(hours: 1);
  DateTime? _lastCheck;

  @override
  UpdateState build() => const UpdateState();

  String? get _platform => Platform.isAndroid
      ? 'android'
      : Platform.isWindows
          ? 'windows'
          : null;

  /// Launch/resume check, at most hourly. Silent on failure.
  Future<void> check({DateTime? now}) async {
    final t = now ?? DateTime.now();
    if (_lastCheck != null && t.difference(_lastCheck!) < _every) return;
    _lastCheck = t;
    try {
      await _fetch();
    } catch (e) {
      AppLog.info('update check failed: ${e.runtimeType} $e');
    }
  }

  /// Settings' "Check for updates": ignores the hourly limit, re-shows a
  /// dismissed banner, and returns a line for the user (errors included).
  Future<String> checkNow() async {
    _lastCheck = DateTime.now();
    try {
      final info = await _fetch();
      if (info == null) return 'Up to date';
      state = state.copyWith(dismissedBuild: 0);
      return 'Update ${info.version} available';
    } catch (e) {
      AppLog.info('update check failed: ${e.runtimeType} $e');
      return 'Update check failed: $e';
    }
  }

  /// The newer release for this platform (also put in [state]), or null.
  Future<UpdateInfo?> _fetch() async {
    final platform = _platform;
    final creds = await ref.read(credsProvider.future);
    if (platform == null) throw Exception('updates are only for Android and Windows');
    if (creds == null) throw Exception('not paired');
    final info = await ref.read(updateApiProvider).latest(creds.baseUrl);
    if (info == null) throw Exception('no release feed at ${latestJsonUrl(creds.baseUrl)}');
    final current = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    if (!info.isAvailable(current, platform)) return null;
    state = state.copyWith(
      info: info,
      manualWindows: platform == 'windows' && UpdateInstaller.writableWindowsInstallDir() == null,
    );
    return info;
  }

  void dismiss() {
    final b = state.info?.build;
    if (b != null) state = state.copyWith(dismissedBuild: b);
  }

  /// Browser fallback URL for the current platform's artifact.
  Future<Uri?> manualUrl() async {
    final f = state.info?.entryFor(_platform ?? '');
    final creds = await ref.read(credsProvider.future);
    return f == null || creds == null ? null : downloadUrl(creds.baseUrl, f.file);
  }

  Future<void> install() async {
    final info = state.info, platform = _platform;
    final f = platform == null ? null : info?.entryFor(platform);
    final creds = await ref.read(credsProvider.future);
    if (f == null || creds == null || state.progress != null) return;
    state = state.copyWith(progress: 0.0, error: null);
    final installer = UpdateInstaller(ref.read(updateApiProvider));
    void onProgress(double p) => state = state.copyWith(progress: p);
    try {
      if (platform == 'android') {
        await installer.installAndroid(creds.baseUrl, f, onProgress);
      } else {
        final dir = UpdateInstaller.writableWindowsInstallDir();
        if (dir == null) {
          state = state.copyWith(manualWindows: true, progress: null);
          return;
        }
        await installer.installWindows(creds.baseUrl, f, dir, onProgress);
      }
      state = state.copyWith(progress: null);
    } catch (e) {
      AppLog.error('update install failed: ${e.runtimeType} $e');
      state = state.copyWith(progress: null, error: 'Update failed: $e');
    }
  }
}
