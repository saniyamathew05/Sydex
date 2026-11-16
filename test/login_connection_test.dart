import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sydex/services/login_connection.dart';

void main() {
  test('recovers from a reset wrapped by the auth SDK', () async {
    var calls = 0;
    final result = await LoginConnection.retry(() async {
      if (++calls == 1) {
        throw AuthRetryableFetchException(message: 'Connection reset by peer');
      }
      return 'signed in';
    });
    expect(result, 'signed in');
    expect(calls, 2);
  });

  test(
    'stops after three attempts when the connection keeps resetting',
    () async {
      var calls = 0;
      final error = Exception('SocketException: Connection reset by peer');
      await expectLater(
        LoginConnection.retry(() async {
          calls++;
          throw error;
        }),
        throwsA(same(error)),
      );
      expect(calls, 3);
    },
  );

  test('does not retry invalid credentials or unrelated failures', () async {
    for (final error in [
      const AuthException('Invalid login credentials'),
      Exception('Permission denied'),
    ]) {
      var calls = 0;
      await expectLater(
        LoginConnection.retry(() async {
          calls++;
          throw error;
        }),
        throwsA(same(error)),
      );
      expect(calls, 1);
    }
  });
}
