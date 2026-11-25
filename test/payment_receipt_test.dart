// http is only needed here to fake the backend for these tests.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sydex/models/customer.dart';
import 'package:sydex/models/transaction.dart';
import 'package:sydex/services/customer_service.dart';
import 'package:sydex/services/payment_receipt_service.dart';
import 'package:sydex/services/payment_receipt_share_service.dart';

const _channel = PaymentReceiptShareService.channel;

final _ledger = [
  {
    'id': 'sale',
    'entry_type': 'purchase',
    'amount': 500,
    'transaction_date': '2026-11-01T10:00:00Z',
    'created_at': '2026-11-01T10:00:00Z',
  },
  {
    'id': 'older',
    'entry_type': 'payment',
    'amount': 200,
    'amount_received': 200,
    'transaction_date': '2026-11-02T10:00:00Z',
    'created_at': '2026-11-02T10:00:00Z',
  },
  {
    'id': 'newest',
    'entry_type': 'payment',
    'amount': 300,
    'amount_received': 300,
    'transaction_date': '2026-11-03T10:00:00Z',
    'created_at': '2026-11-03T10:00:00Z',
  },
  {
    'id': 'bounced',
    'entry_type': 'payment',
    'amount': 50,
    'is_bounced': true,
    'transaction_date': '2026-11-04T10:00:00Z',
    'created_at': '2026-11-04T10:00:00Z',
  },
];

Future<http.Response> _backend(http.Request request) async {
  http.Response reply(Object? body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
    request: request,
  );
  final path = request.url.path;
  if (path.endsWith('/ledger_entries')) return reply(_ledger);
  if (path.endsWith('/update_customer_phone')) {
    final sent = jsonDecode(request.body) as Map<String, dynamic>;
    return reply({
      'id': 'c',
      'business_name': 'Amba Stores',
      'location': 'Town',
      'phone': sent['p_phone'],
      'opening_balance': 1000,
    });
  }
  return reply(<Object>[]);
}

Customer _customer(String phone) => Customer(
  id: 'c',
  businessName: 'Amba Stores',
  location: 'Town',
  phone: phone,
  openingBalance: 1000,
);

void main() {
  late List<MethodCall> calls;
  late List<String> apps;
  Object? error;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      publishableKey: 'test-only-placeholder',
      httpClient: MockClient(_backend),
    );
  });

  setUp(() async {
    calls = [];
    apps = ['com.whatsapp'];
    error = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'whatsAppApps' => apps,
            'sendToWhatsApp' => true,
            'copyImage' => true,
            _ => null,
          };
        });
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Waits for a result that depends on the (fake) backend, however slow the
  /// computer is.
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
  }

  bool handedOver() =>
      error != null || calls.any((c) => c.method == 'sendToWhatsApp');

  Future<void> press(
    WidgetTester tester,
    Customer customer, {
    String? paymentId,
  }) async {
    CustomerService.customers
      ..clear()
      ..add(customer);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                try {
                  await PaymentReceiptShareService.send(
                    context: context,
                    customer: customer,
                    paymentId: paymentId,
                  );
                } catch (caught) {
                  error = caught;
                }
              },
              child: const Text('Receipt'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Receipt'));
    await waitFor(
      tester,
      () =>
          handedOver() ||
          find.byType(AlertDialog).evaluate().isNotEmpty ||
          find.byType(BottomSheet).evaluate().isNotEmpty,
    );
  }

  Map<Object?, Object?> sent() =>
      calls.singleWhere((c) => c.method == 'sendToWhatsApp').arguments as Map;

  test('phone numbers become WhatsApp numbers', () {
    String? number(String raw) =>
        PaymentReceiptShareService.whatsAppNumber(raw);
    expect(number('98470 12345'), '919847012345');
    expect(number('098470-12345'), '919847012345');
    expect(number('+91 98470 12345'), '919847012345');
    expect(number('919847012345'), '919847012345');
    expect(number('0091 98470 12345'), '919847012345');
    expect(number('+971 50 123 4567'), '971501234567');
    expect(number(''), isNull);
    expect(number('12345'), isNull);
    expect(number('98470 12345 / 98470 54321'), isNull);
  });

  testWidgets('the latest real payment goes to the customer’s chat', (
    tester,
  ) async {
    await press(tester, _customer('98470 12345'));
    expect(error, isNull);
    expect(sent()['phone'], '919847012345');
    expect(sent()['app'], 'com.whatsapp');
    // Not the bounced cheque entered after it.
    expect(sent()['name'], 'payment-receipt-newest.png');
    expect((sent()['image']! as Uint8List).take(4), [137, 80, 78, 71]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a chosen payment sends its own receipt', (tester) async {
    await press(tester, _customer('9847012345'), paymentId: 'older');
    expect(error, isNull);
    expect(sent()['name'], 'payment-receipt-older.png');
  });

  testWidgets('a missing number is asked for and saved', (tester) async {
    await press(tester, _customer(''));
    expect(find.text('Add a WhatsApp number'), findsOneWidget);
    expect(calls, isEmpty);

    await tester.enterText(find.byType(TextFormField), '123');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('Enter one full phone number.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '9847012345');
    await tester.tap(find.text('Save'));
    await waitFor(tester, handedOver);
    expect(error, isNull);
    expect(sent()['phone'], '919847012345');
    expect(CustomerService.getCustomerById('c')!.phone, '9847012345');
  });

  testWidgets('with both WhatsApps the choice is asked once', (tester) async {
    apps = ['com.whatsapp', 'com.whatsapp.w4b'];
    await press(tester, _customer('9847012345'));
    await tester.tap(find.text('WhatsApp Business'));
    await waitFor(tester, handedOver);
    expect(sent()['app'], 'com.whatsapp.w4b');

    calls.clear();
    await press(tester, _customer('9847012345'));
    expect(sent()['app'], 'com.whatsapp.w4b');
  });

  testWidgets('Windows copies the receipt and says what to press', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await press(tester, _customer('9847012345'));
    final copied =
        calls.singleWhere((c) => c.method == 'copyImage').arguments as Map;
    expect(
      (copied['rgba'] as Uint8List).length,
      (copied['width'] as int) * (copied['height'] as int) * 4,
    );
    expect(find.textContaining('Ctrl+V'), findsOneWidget);
    expect(find.textContaining('+919847012345'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(error, isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a split payment makes room for each method', (tester) async {
    await tester.runAsync(() async {
      Future<int> height(String note) async {
        final png = await PaymentReceiptService.buildReceiptImage(
          PaymentTransaction(
            id: 'p',
            customerId: 'c',
            customerName: 'Amba Stores',
            amount: 100,
            discount: 0,
            previousBalance: 100,
            remainingBalance: -20,
            transactionDate: DateTime(2026, 11, 3),
            notes: '',
            signature: Uint8List(0),
            paymentMethodNote: note,
          ),
        );
        final codec = await ui.instantiateImageCodec(png);
        return (await codec.getNextFrame()).image.height;
      }

      expect(await height(''), 1260);
      expect(
        await height('Split amounts: cash=40.00;cheque=30.00;gpay=30.00'),
        greaterThan(1300),
      );
    });
  });
}
