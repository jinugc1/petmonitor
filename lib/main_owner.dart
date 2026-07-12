import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app/theme.dart';
import 'core/providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/owner/devices_screen.dart';
import 'features/owner/owner_call_screen.dart';
import 'features/owner/owner_settings_screen.dart';
import 'features/owner/receive_access_screen.dart';
import 'features/owner/share_access_screen.dart';
import 'features/pairing/owner_pairing_screen.dart';
import 'firebase_options.dart';

/// Owner App entry point (iOS).
///
///   flutter run -t lib/main_owner.dart
///   flutter build ipa -t lib/main_owner.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const ProviderScope(child: OwnerApp()));
}

class OwnerApp extends ConsumerWidget {
  const OwnerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      title: 'PetMonitor',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
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
    initialLocation: '/devices',
    refreshListenable: authState,
    redirect: (context, state) {
      final signedIn = authState.value;
      if (signedIn == null) return null; // still resolving
      final onSignIn = state.matchedLocation == '/signin';
      if (!signedIn) return onSignIn ? null : '/signin';
      if (onSignIn) return '/devices';
      return null;
    },
    routes: [
      GoRoute(
        path: '/signin',
        builder: (_, __) => const SignInScreen(
          subtitle: 'See and talk to your pet from anywhere',
        ),
      ),
      GoRoute(path: '/devices', builder: (_, __) => const DevicesScreen()),
      GoRoute(path: '/pair', builder: (_, __) => const OwnerPairingScreen()),
      GoRoute(path: '/call', builder: (_, __) => const OwnerCallScreen()),
      GoRoute(
        path: '/settings',
        builder: (_, __) => const OwnerSettingsScreen(),
      ),
      GoRoute(
        path: '/share/:id',
        builder: (_, state) =>
            ShareAccessScreen(deviceId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/receive',
        builder: (_, __) => const ReceiveAccessScreen(),
      ),
    ],
  );
});
