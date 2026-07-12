import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'crypto/call_authenticator.dart';
import 'crypto/key_store.dart';
import 'fcm/fcm_direct_sender.dart';
import 'webrtc/ice_config.dart';

/// Composition root: every service is injected through Riverpod so all
/// layers stay testable (repositories receive fakes in tests).
final firebaseAuthProvider =
    Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

final firestoreProvider =
    Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);

final messagingProvider =
    Provider<FirebaseMessaging>((ref) => FirebaseMessaging.instance);

final keyStoreProvider = Provider<KeyStore>((ref) => KeyStore());

final callAuthenticatorProvider =
    Provider<CallAuthenticator>((ref) => CallAuthenticator());

final iceConfigStoreProvider =
    Provider<IceConfigStore>((ref) => IceConfigStore());

/// Spark-plan wake path: direct FCM HTTP v1 sends from the owner device.
final fcmDirectSenderProvider = Provider<FcmDirectSender>((ref) {
  final sender = FcmDirectSender();
  ref.onDispose(sender.dispose);
  return sender;
});

/// Current Firebase user (null while signed out).
final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(firebaseAuthProvider).authStateChanges(),
);
