import 'dart:io';

/// Phone vs desktop (ADR 0015). Mobile-only plugins — FCM, share intents,
/// camera, on-device speech — are gated on this; desktop builds skip them.
final bool isMobile = Platform.isAndroid || Platform.isIOS;
