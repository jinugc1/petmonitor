import 'dart:async';
import 'dart:math';

/// Exponential backoff with full jitter, used for every retry loop in the
/// app (Firestore reconnect, FCM re-registration, ICE restart, heartbeat).
class ExponentialBackoff {
  ExponentialBackoff({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(minutes: 2),
    this.multiplier = 2.0,
    Random? random,
  }) : _random = random ?? Random.secure();

  final Duration initial;
  final Duration max;
  final double multiplier;
  final Random _random;

  int _attempt = 0;

  int get attempt => _attempt;

  /// Next delay: full jitter over the exponential ceiling.
  Duration next() {
    final ceilingMs = min(
      max.inMilliseconds.toDouble(),
      initial.inMilliseconds * pow(multiplier, _attempt),
    );
    _attempt++;
    return Duration(milliseconds: (_random.nextDouble() * ceilingMs).round());
  }

  void reset() => _attempt = 0;

  /// Runs [action] until it succeeds or [maxAttempts] is exhausted.
  Future<T> retry<T>(
    Future<T> Function() action, {
    int maxAttempts = 8,
    bool Function(Object error)? retryIf,
  }) async {
    reset();
    while (true) {
      try {
        return await action();
      } catch (e) {
        if (_attempt + 1 >= maxAttempts || (retryIf != null && !retryIf(e))) {
          rethrow;
        }
        await Future<void>.delayed(next());
      }
    }
  }
}
