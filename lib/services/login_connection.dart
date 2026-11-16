import 'package:supabase_flutter/supabase_flutter.dart';

/// Only use for repeatable login operations, never payments or token exchanges.
class LoginConnection {
  static bool isConnectionReset(Object error) {
    // Never retry rejected credentials or other server-side auth decisions.
    if (error is AuthException && error is! AuthRetryableFetchException) {
      return false;
    }
    final message = error.toString().toLowerCase();
    return message.contains('connection reset by peer') ||
        message.contains('connection closed before full header was received') ||
        message.contains('connection reset');
  }

  static Future<T> retry<T>(Future<T> Function() operation) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await operation();
      } catch (error) {
        if (attempt >= 2 || !isConnectionReset(error)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }

  static String errorMessage(Object error) => isConnectionReset(error)
      ? 'The connection was interrupted. Try switching between Wi-Fi and mobile data, then sign in again.'
      : error is AuthException
      ? error.message
      : error.toString().replaceFirst('Exception: ', '');
}
