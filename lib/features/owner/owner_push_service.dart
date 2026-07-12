import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/firebase/firestore_paths.dart';
import '../../core/providers.dart';

/// Registers the owner phone's FCM token under users/{uid}.fcmTokens so
/// the event fan-out function can notify it (device offline, battery low,
/// reboot...). Multiple owner phones are supported: tokens are a map of
/// token -> lastSeen, pruned opportunistically after 60 days.
final ownerPushInitProvider = FutureProvider<void>((ref) async {
  // FCM has no Windows/desktop implementation; alerts there are shown by
  // the dashboard itself (device cards go offline/red in near-real-time).
  if (!Platform.isAndroid && !Platform.isIOS) return;
  final user = ref.watch(authStateProvider).value;
  if (user == null) return;

  final messaging = ref.read(messagingProvider);
  final firestore = ref.read(firestoreProvider);

  await messaging.requestPermission();

  Future<void> register(String token) async {
    await firestore.doc(FirestorePaths.user(user.uid)).set(
      {
        'fcmTokens': {token: DateTime.now().toUtc().millisecondsSinceEpoch},
      },
      SetOptions(merge: true),
    );
  }

  final token = await messaging.getToken();
  if (token != null) await register(token);

  final sub = messaging.onTokenRefresh.listen(register);
  ref.onDispose(sub.cancel);
});
