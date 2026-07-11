import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../core/providers.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(firebaseAuthProvider)),
);

/// Email/password, Google, and Apple sign-in against Firebase Auth.
class AuthRepository {
  AuthRepository(this._auth);

  final FirebaseAuth _auth;

  Future<UserCredential> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<UserCredential> registerWithEmail(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email, password: password);

  Future<UserCredential> signInWithGoogle() async {
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) {
      throw FirebaseAuthException(code: 'canceled');
    }
    final googleAuth = await googleUser.authentication;
    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      ),
    );
  }

  Future<UserCredential> signInWithApple() async {
    final apple = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    return _auth.signInWithCredential(
      OAuthProvider('apple.com').credential(
        idToken: apple.identityToken,
        accessToken: apple.authorizationCode,
      ),
    );
  }

  Future<void> signOut() => _auth.signOut();
}
