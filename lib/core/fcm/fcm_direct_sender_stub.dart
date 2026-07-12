import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Web build of [FcmDirectSender]: service-account OAuth (dart:io based)
/// is unavailable in browsers, and the web owner client doesn't need it —
/// on the Blaze plan the onCallSessionCreated Cloud Function sends the
/// wake push for every session regardless of which client created it.
class FcmDirectSender {
  FcmDirectSender([FlutterSecureStorage? storage]);

  Future<bool> get isConfigured async => false;

  Future<void> saveServiceAccount(String jsonText) async {
    throw const FormatException(
      'Direct wake-push keys are not supported in the web app. Calls '
      'from the web still wake the monitor via the Cloud Function.',
    );
  }

  Future<void> clear() async {}

  Future<void> sendCallWake({
    required String fcmToken,
    required String deviceId,
    required String sessionId,
  }) async {
    throw StateError('FcmDirectSender is unavailable on the web');
  }

  void dispose() {}
}
