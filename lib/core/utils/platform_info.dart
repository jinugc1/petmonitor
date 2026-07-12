import 'package:flutter/foundation.dart';

/// Web-safe platform checks (dart:io's Platform throws on web).
bool get isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

bool get isIosPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
