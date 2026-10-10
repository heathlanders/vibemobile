import 'dart:io';

import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// Phone vs desktop (ADR 0015). Mobile-only plugins — FCM, share intents,
/// camera, on-device speech — are gated on this; desktop builds skip them.
final bool isMobile = Platform.isAndroid || Platform.isIOS;

/// Shortest logical side below which a mobile device is a phone (proposal 54).
const phoneShortestSide = 600.0;

/// A phone: a mobile platform whose [screen] (logical px) has a shortest side
/// under [phoneShortestSide]. Orientation-independent, so a phone held in
/// landscape is still a phone. Reads [defaultTargetPlatform] so tests can
/// override the platform.
bool isPhone(Size screen) =>
    (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) &&
    screen.shortestSide < phoneShortestSide;
