import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:petmonitor/core/utils/backoff.dart';

void main() {
  test('delays stay within the exponential ceiling and the max', () {
    final b = ExponentialBackoff(
      initial: const Duration(milliseconds: 100),
      max: const Duration(seconds: 2),
      random: Random(42),
    );
    for (var i = 0; i < 20; i++) {
      final d = b.next();
      final ceiling = min(2000, 100 * pow(2, i)).toDouble();
      expect(d.inMilliseconds, lessThanOrEqualTo(ceiling.ceil()));
      expect(d.inMilliseconds, greaterThanOrEqualTo(0));
    }
  });

  test('reset starts the schedule over', () {
    final b = ExponentialBackoff(random: Random(1));
    b.next();
    b.next();
    expect(b.attempt, 2);
    b.reset();
    expect(b.attempt, 0);
  });

  test('retry succeeds after transient failures', () async {
    final b = ExponentialBackoff(
      initial: const Duration(milliseconds: 1),
      max: const Duration(milliseconds: 2),
      random: Random(7),
    );
    var attempts = 0;
    final result = await b.retry(() async {
      attempts++;
      if (attempts < 3) throw StateError('flaky');
      return 'ok';
    });
    expect(result, 'ok');
    expect(attempts, 3);
  });

  test('retry gives up after maxAttempts', () async {
    final b = ExponentialBackoff(
      initial: const Duration(milliseconds: 1),
      max: const Duration(milliseconds: 2),
      random: Random(7),
    );
    var attempts = 0;
    await expectLater(
      b.retry(
        () async {
          attempts++;
          throw StateError('always');
        },
        maxAttempts: 4,
      ),
      throwsA(isA<StateError>()),
    );
    expect(attempts, 4);
  });

  test('retryIf stops retrying on non-retryable errors', () async {
    final b = ExponentialBackoff(
      initial: const Duration(milliseconds: 1),
      random: Random(7),
    );
    var attempts = 0;
    await expectLater(
      b.retry(
        () async {
          attempts++;
          throw ArgumentError('fatal');
        },
        retryIf: (e) => e is StateError,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(attempts, 1);
  });
}
