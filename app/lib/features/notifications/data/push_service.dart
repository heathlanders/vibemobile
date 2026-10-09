import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/token_store.dart';
import '../domain/push_note.dart';
import 'push_api.dart';

/// FCM wake-up → local notification with Allow/Deny or option buttons (ADR 0013).
///
/// The push is data-only `{type, sessionId}`; on receipt (main or background
/// isolate) we fetch `/sessions/:id/pending` from the daemon and render it
/// locally. Actions answer over REST without opening the app. Prompt
/// notifications are `VISIBILITY_SECRET`: never drawn on a secure lock screen,
/// so approving a shell command always needs an unlocked phone (the plugin has
/// no per-action setAuthenticationRequired).
class PushService {
  PushService._();

  static final _local = FlutterLocalNotificationsPlugin();

  /// Per-session "is it on screen right now?" checks, registered by ChatScreen
  /// and the multi-chat grid (a chat under another route is mounted but not
  /// visible). A visible session's prompts are already on screen as a card, so
  /// they never notify.
  static final _visible = <String, Set<bool Function()>>{};

  static void registerVisible(String sessionId, bool Function() isVisible) =>
      (_visible[sessionId] ??= {}).add(isVisible);

  static void unregisterVisible(String sessionId, bool Function() isVisible) {
    final s = _visible[sessionId];
    s?.remove(isVisible);
    if (s != null && s.isEmpty) _visible.remove(sessionId);
  }

  static bool isVisible(String sessionId) =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      (_visible[sessionId]?.any((f) => f()) ?? false);

  /// A prompt frame reached an attached-but-off-screen session (another chat or
  /// dir is open): the daemon won't push since a client is attached, so notify
  /// locally. Same builder + stable id as the push path, so the two replace
  /// rather than duplicate.
  static Future<void> notifyPrompt(String sessionId, String? title, Map<String, dynamic> frame) async {
    if (isVisible(sessionId)) return;
    final isPermission = frame['t'] == 'permission_request';
    final pending = {
      'title': title,
      'permissions': isPermission ? [frame] : const [],
      'dialogs': isPermission ? const [] : [frame],
    };
    try {
      for (final n in buildNotes(isPermission ? 'permission' : 'question', sessionId, pending)) {
        await _show(n);
      }
    } catch (e) {
      debugPrint('local prompt notify failed: $e');
    }
  }

  static void Function(String sessionId)? _onOpen;
  static String? _pendingOpen;

  /// Where a notification tap routes. A tap that arrives before the app wires
  /// this up (cold start) is held and delivered on assignment.
  static set onOpenSession(void Function(String sessionId)? f) {
    _onOpen = f;
    final held = _pendingOpen;
    if (f != null && held != null) {
      _pendingOpen = null;
      f(held);
    }
  }

  static void _open(String sessionId) {
    final f = _onOpen;
    if (f == null) {
      _pendingOpen = sessionId;
    } else {
      f(sessionId);
    }
  }

  /// Wire FCM + local notifications. Called once from main(); fail-soft — a
  /// missing Firebase config must never keep the app from starting.
  static Future<void> init() async {
    if (!isMobile) {
      // Desktop (ADR 0015): no FCM. Local notifications only, fed by notifyPrompt
      // while the app is open; taps open the session, no action buttons.
      try {
        await _initLocal();
      } catch (e) {
        debugPrint('local notify init failed: $e');
      }
      return;
    }
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
      await _initLocal();
      FirebaseMessaging.onMessage.listen((m) {
        final id = m.data['sessionId'];
        if (id is String && isVisible(id)) return;
        unawaited(_handleMessage(m.data));
      });
      final launch = await _local.getNotificationAppLaunchDetails();
      final r = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && r != null) unawaited(_onResponse(r));
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      FirebaseMessaging.instance.onTokenRefresh.listen((t) => unawaited(_register(t)));
      unawaited(registerToken());
    } catch (e) {
      debugPrint('push init failed: $e');
    }
  }

  /// POST the current FCM token (startup, and right after pairing).
  static Future<void> registerToken() async {
    if (!isMobile) return; // desktop has no FCM token
    try {
      final t = await FirebaseMessaging.instance.getToken();
      if (t != null) await _register(t);
    } catch (e) {
      debugPrint('push token register failed: $e');
    }
  }

  static Future<void> _register(String token) async {
    final creds = await const TokenStore().read();
    if (creds == null) return; // unpaired — pairing calls registerToken()
    await PushApi(dioFor(creds)).registerToken(token);
  }

  static Future<void> _initLocal() => _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'VibeMobile',
            appUserModelId: 'com.vibemobile.vibemobile',
            guid: '5b0f3c9e-8a4d-4f6e-9c2b-7d1e3a6f8b40',
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
        onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationResponse,
      );

  static Future<Creds?> _creds() => const TokenStore().read();

  /// Fetch what the session is waiting on and show it.
  static Future<void> _handleMessage(Map<String, dynamic> data) async {
    final type = data['type'] as String?;
    final sessionId = data['sessionId'] as String?;
    if (type == 'system_alert') {
      await _show(systemAlertNote()); // nothing to fetch — the push carries no details
      return;
    }
    if (type == 'usage_reset') {
      await _show(usageResetNote());
      return;
    }
    if (type == null || sessionId == null) return;
    final creds = await _creds();
    if (creds == null) return;
    final pending = await PushApi(dioFor(creds)).pending(sessionId);
    if (pending == null) return;
    for (final n in buildNotes(type, sessionId, pending)) {
      await _show(n);
    }
  }

  static Future<void> _show(PushNote n) => _local.show(
        id: n.id,
        title: n.title,
        body: n.body,
        payload: n.payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            n.prompt ? 'vibe_prompts' : 'vibe_done',
            n.prompt ? 'Approvals & questions' : 'Finished turns',
            channelDescription: n.prompt
                ? 'Claude is waiting on you (permission or question).'
                : 'A Claude turn finished while the app was closed.',
            importance: n.prompt ? Importance.high : Importance.defaultImportance,
            priority: n.prompt ? Priority.high : Priority.defaultPriority,
            visibility: n.prompt ? NotificationVisibility.secret : NotificationVisibility.private,
            category: n.prompt ? AndroidNotificationCategory.message : AndroidNotificationCategory.status,
            onlyAlertOnce: true,
            styleInformation: BigTextStyleInformation(n.body),
            actions: [for (final (id, label) in n.actions) AndroidNotificationAction(id, label)],
          ),
        ),
      );

  /// Body tap → open the session; action tap → answer it over REST.
  static Future<void> _onResponse(NotificationResponse r) async {
    final p = NotePayload.decode(r.payload);
    if (p == null) return;
    if (r.notificationResponseType == NotificationResponseType.selectedNotification) {
      _open(p.sessionId);
      return;
    }
    await answerFromAction(r);
  }

  /// Send the answer an action maps to. Runs in either isolate.
  static Future<void> answerFromAction(NotificationResponse r) async {
    final p = NotePayload.decode(r.payload);
    if (p == null) return;
    final answer = answerFor(p, r.actionId);
    final creds = await _creds();
    if (answer == null || creds == null) return;
    final api = PushApi(dioFor(creds));
    final status = switch (answer) {
      PermissionAnswer(:final toolUseID, :final allow) => await api.answerPermission(p.sessionId, toolUseID, allow),
      DialogAnswer(:final dialogId, :final result) => await api.answerDialog(p.sessionId, dialogId, result),
    };
    if (status == 410) {
      await _local.show(
        id: r.id ?? stableNoteId(p.requestId ?? p.sessionId),
        title: 'Expired',
        body: 'Request already timed out or was answered.',
        payload: NotePayload(sessionId: p.sessionId, kind: 'done').encode(),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('vibe_done', 'Finished turns', timeoutAfter: 10000),
        ),
      );
    } else if (r.id != null) {
      await _local.cancel(id: r.id!);
    }
  }
}

/// FCM data message while the app is backgrounded/killed (own isolate).
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage m) async {
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp();
  await PushService._initLocal();
  await PushService._handleMessage(m.data);
}

/// Action tapped with the app not in the foreground (plugin's own isolate).
@pragma('vm:entry-point')
Future<void> onBackgroundNotificationResponse(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  await PushService.answerFromAction(r);
}
