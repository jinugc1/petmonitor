import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app/theme.dart';
import 'core/providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/monitor/monitor_call_screen.dart';
import 'features/monitor/standby_screen.dart';
import 'features/pairing/monitor_pairing_screen.dart';
import 'firebase_options.dart';

/// FCM background handler — runs in its own isolate while the app is
/// dormant. It does NOT validate or answer the call (no UI, no WebRTC in
/// this isolate); it only posts a full-screen-intent notification, which
/// makes Android turn on the screen and launch MainActivity even from the
/// lock screen. The launched app then authenticates the session
/// cryptographically before auto-answering.
@pragma('vm:entry-point')
Future<void> monitorBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] != 'incoming_call') return;
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  final notifications = FlutterLocalNotificationsPlugin();
  const channel = AndroidNotificationChannel(
    'incoming_calls',
    'Incoming calls',
    description: 'Owner is calling',
    importance: Importance.max,
  );
  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await notifications.show(
    1001,
    'PetMonitor',
    'Incoming call from owner…',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'incoming_calls',
        'Incoming calls',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true, // wakes screen + launches the activity
        autoCancel: true,
        timeoutAfter: 60000,
      ),
    ),
  );
}

/// Pet Monitor App entry point (Android).
///
///   flutter run -t lib/main_monitor.dart
///   flutter build apk -t lib/main_monitor.dart --release
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // No offline persistence on the monitor: it is a live device and the
  // SQLite cache otherwise grows with every heartbeat until old 32-bit
  // hardware exhausts native memory (observed CursorWindowAllocation
  // crash after days of uptime).
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: false,
  );
  FirebaseMessaging.onBackgroundMessage(monitorBackgroundHandler);
  runApp(const ProviderScope(child: MonitorApp()));
}

class MonitorApp extends ConsumerWidget {
  const MonitorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      title: 'PetMonitor — Monitor',
      theme: buildTheme(Brightness.dark), // monitor lives in dark mode
      routerConfig: router,
    );
  }
}

final _routerProvider = Provider<GoRouter>((ref) {
  final authState = ValueNotifier<bool?>(null);
  ref
    ..listen(
      authStateProvider,
      (_, next) => authState.value = next.value != null,
      fireImmediately: true,
    )
    ..onDispose(authState.dispose);

  return GoRouter(
    initialLocation: '/standby',
    refreshListenable: authState,
    redirect: (context, state) {
      final signedIn = authState.value;
      if (signedIn == null) return null;
      final onSignIn = state.matchedLocation == '/signin';
      if (!signedIn) return onSignIn ? null : '/signin';
      if (onSignIn) return '/standby';
      return null;
    },
    routes: [
      GoRoute(
        path: '/signin',
        builder: (_, __) => const SignInScreen(
          subtitle: 'Set up this phone as a pet monitor\n'
              '(sign in with the owner account)',
        ),
      ),
      GoRoute(path: '/pair', builder: (_, __) => const MonitorPairingScreen()),
      GoRoute(path: '/standby', builder: (_, __) => const StandbyScreen()),
      GoRoute(path: '/call', builder: (_, __) => const MonitorCallScreen()),
    ],
  );
});
