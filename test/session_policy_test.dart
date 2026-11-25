import 'package:flutter_test/flutter_test.dart';
import 'package:sydex/services/session_policy.dart';

void main() {
  test('the idle limit is ten minutes and the message says so', () {
    expect(SessionPolicy.idleLimit, const Duration(minutes: 10));
    expect(
      SessionPolicy.idleMessage,
      contains('${SessionPolicy.idleLimit.inMinutes} minutes'),
    );
  });
}
