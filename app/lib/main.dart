import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'core/app_log.dart';
import 'core/platform.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'core/theme_controller.dart';
import 'core/widgets.dart';
import 'features/chat/presentation/share_image_screen.dart';
import 'features/chat/presentation/chat_screen.dart';
import 'features/dashboard/presentation/dashboard_screen.dart';
import 'features/dashboard/presentation/desktop_shell.dart';
import 'features/notifications/data/push_service.dart';
import 'features/pairing/presentation/pairing_screen.dart';
import 'features/sessions/data/session_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Client error log (Settings → Copy logs): uncaught framework/async errors.
  await AppLog.init();
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (d) {
    AppLog.error('flutter: ${d.exceptionAsString()}');
    prevOnError?.call(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    AppLog.error('uncaught: $e\n$st');
    return false; // keep default handling (console)
  };
  // Push (ADR 0013): FCM + local notifications. Fail-soft — never blocks startup.
  await PushService.init();
  runApp(const ProviderScope(child: VibeMobileApp()));
}

class VibeMobileApp extends ConsumerStatefulWidget {
  const VibeMobileApp({super.key});

  @override
  ConsumerState<VibeMobileApp> createState() => _VibeMobileAppState();
}

class _VibeMobileAppState extends ConsumerState<VibeMobileApp> {
  final _navKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    if (isMobile) {
      // Warm: a share arrives while the app is already running.
      _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(_handleShare, onError: (_) {});
      // Cold: the app was launched by the share itself.
      ReceiveSharingIntent.instance.getInitialMedia().then((media) {
        _handleShare(media);
        ReceiveSharingIntent.instance.reset();
      });
    }
    // Notification tap → that session's chat (a cold-start tap is held until now).
    PushService.onOpenSession = _openSession;
  }

  Future<void> _openSession(String sessionId) async {
    final creds = await ref.read(tokenStoreProvider).read();
    if (creds == null) return;
    final s = await SessionApi(dioFor(creds)).get(sessionId).catchError((_) => null);
    if (s == null || s.kind != 'claude') return;
    _navKey.currentState?.push(sharedAxisRoute(ChatScreen(creds: creds, session: s)));
  }

  /// Route a shared image into a session picker. Images only; non-image shares
  /// (text/url) are ignored. Drops the share with a nudge if unpaired — a share
  /// can't attach to a session without creds.
  Future<void> _handleShare(List<SharedMediaFile> media) async {
    final imageFiles = media.where((m) => m.type == SharedMediaType.image);
    final bytes = <Uint8List>[];
    for (final m in imageFiles) {
      try {
        bytes.add(await File(m.path).readAsBytes());
      } catch (_) {/* temp file vanished — skip it */}
    }
    if (bytes.isEmpty) return;

    final creds = await ref.read(tokenStoreProvider).read();
    if (creds == null) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Pair VibeMobile first to share images.')),
      );
      return;
    }
    _navKey.currentState?.push(
      sharedAxisRoute(ShareImageScreen(creds: creds, imageBytes: bytes)),
    );
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    PushService.onOpenSession = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VibeMobile',
      navigatorKey: _navKey,
      scaffoldMessengerKey: _messengerKey,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ref.watch(themeModeProvider),
      home: const _Root(),
      builder: AppTheme.capToastWidth,
    );
  }
}

/// Routes on credential presence: paired → session list, else → pairing.
/// `credsProvider` re-evaluates after pair/sign-out (`ref.invalidate`).
/// Paired + desktop platform (or a wide window) → [DesktopShell]; otherwise
/// the phone dashboard.
class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creds = ref.watch(credsProvider);
    return creds.when(
      data: (c) {
        if (c == null) return const PairingScreen();
        return DesktopShell.shown(context) ? DesktopShell(creds: c) : DashboardScreen(creds: c);
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
    );
  }
}
