import 'package:flutter_test/flutter_test.dart';
import 'package:sydex/services/payment_method_breakdown.dart';

void main() {
  test('note text hides the stored split but keeps the written note', () {
    expect(
      PaymentMethodBreakdown.noteText(
        'Cheque no 1123 • Split amounts: cash=24500.00;cheque=19534.00',
      ),
      'Cheque no 1123',
    );
    expect(
      PaymentMethodBreakdown.noteText('Split amounts: cash=1.00;gpay=2.00'),
      '',
    );
    expect(PaymentMethodBreakdown.noteText('UPI ref 88'), 'UPI ref 88');
    expect(PaymentMethodBreakdown.noteText(null), '');
  });
}
