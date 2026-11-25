import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/customer.dart';
import '../models/transaction.dart';
import 'customer_service.dart';
import 'payment_receipt_service.dart';
import 'transaction_service.dart';

/// Sends payment receipts through the WhatsApp on this device: it opens the
/// customer's chat with the receipt ready, and the person presses Send.
class PaymentReceiptShareService {
  PaymentReceiptShareService._();

  static const channel = MethodChannel('sydex/receipt');
  static const _appPreference = 'sydex_whatsapp_app';
  static const _appNames = {
    'com.whatsapp': 'WhatsApp',
    'com.whatsapp.w4b': 'WhatsApp Business',
  };

  /// The number WhatsApp needs: digits with the country code and no "+".
  /// Returns null when the saved phone cannot be a single valid number.
  static String? whatsAppNumber(String saved) {
    final raw = saved.trim();
    final international = raw.startsWith('+') || raw.startsWith('00');
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (!international) {
      if (digits.length == 11 && digits.startsWith('0')) {
        digits = digits.substring(1);
      }
      // Local customer numbers use India's country code.
      if (digits.length == 10) digits = '91$digits';
    }
    return digits.length < 10 || digits.length > 15 ? null : digits;
  }

  static String errorText(Object error) => error is StateError
      ? error.message
      : 'Check the connection and try again.';

  static Future<void> openCustomerChat(Customer customer) async {
    final number = whatsAppNumber(customer.phone);
    if (number == null) {
      throw StateError('Enter a valid customer phone number first.');
    }
    await _openChat(number);
  }

  static Future<void> _openChat(String number) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      // Goes straight to the desktop app, without a browser page in between.
      final app = Uri.parse('whatsapp://send?phone=$number');
      if (await canLaunchUrl(app) && await launchUrl(app)) return;
    }
    if (!await launchUrl(
      Uri.https('wa.me', '/$number'),
      mode: LaunchMode.externalApplication,
    )) {
      throw StateError('Could not open WhatsApp.');
    }
  }

  /// Sends the receipt of [paymentId], or of the latest payment.
  static Future<void> send({
    required BuildContext context,
    required Customer customer,
    String? paymentId,
  }) async {
    // The saved customer has the opening balance and the newest number.
    var recipient = CustomerService.getCustomerById(customer.id) ?? customer;
    final number = await _numberFor(context, recipient);
    if (number == null || !context.mounted) return;
    recipient = CustomerService.getCustomerById(customer.id) ?? recipient;

    final payment = await _payment(recipient, paymentId);
    final signature = await _signature(payment);
    final image = await PaymentReceiptService.buildReceiptImage(
      payment,
      signatureBytes: signature,
    );
    if (!context.mounted) return;
    final name = 'payment-receipt-${payment.id}.png';

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final opened = await _sendOnAndroid(context, number, image, name);
      if (opened != false || !context.mounted) return;
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final opened = await _sendOnWindows(context, recipient, number, image);
      if (opened != false || !context.mounted) return;
    }
    await _share(context, image, name);
  }

  /// The customer's WhatsApp number, asking for it when it is missing.
  static Future<String?> _numberFor(
    BuildContext context,
    Customer customer,
  ) async {
    final saved = whatsAppNumber(customer.phone);
    if (saved != null) return saved;

    final formKey = GlobalKey<FormState>();
    var typed = customer.phone.trim();
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          customer.phone.trim().isEmpty
              ? 'Add a WhatsApp number'
              : 'Check the WhatsApp number',
        ),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: typed,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Number for ${customer.businessName}',
              hintText: 'e.g. 98765 43210',
            ),
            onChanged: (value) => typed = value.trim(),
            validator: (value) => whatsAppNumber(value ?? '') == null
                ? 'Enter one full phone number.'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, typed);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (entered == null) return null;
    final updated = await CustomerService.updateCustomerPhone(
      customerId: customer.id,
      phone: entered,
    );
    if (updated == null) {
      throw StateError(
        CustomerService.errorMessage ?? 'Could not save the phone number.',
      );
    }
    return whatsAppNumber(entered);
  }

  static Future<PaymentTransaction> _payment(
    Customer customer,
    String? paymentId,
  ) async {
    final entries = await TransactionService.getCustomerLedger(
      customer.id,
      openingBalance: customer.openingBalance,
    );
    final payments = entries
        .where((entry) => entry['entry_type'] == 'payment')
        .toList();
    final Map<String, dynamic> entry;
    if (paymentId != null) {
      entry = payments.firstWhere(
        (entry) => entry['id']?.toString() == paymentId,
        orElse: () => throw StateError('This payment could not be found.'),
      );
    } else {
      // A bounced cheque is not a payment the customer should get a receipt for.
      payments.removeWhere((entry) => entry['is_bounced'] == true);
      if (payments.isEmpty) {
        throw StateError('There is no payment receipt to send yet.');
      }
      DateTime enteredAt(Map<String, dynamic> entry) =>
          DateTime.tryParse(entry['created_at']?.toString() ?? '') ??
          DateTime.tryParse(entry['transaction_date']?.toString() ?? '') ??
          DateTime(0);
      payments.sort((a, b) => enteredAt(b).compareTo(enteredAt(a)));
      entry = payments.first;
    }
    return paymentFromEntry(entry, customer);
  }

  static PaymentTransaction paymentFromEntry(
    Map<String, dynamic> entry,
    Customer customer,
  ) {
    final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
    final discount = (entry['discount'] as num?)?.toDouble() ?? 0;
    final profile = entry['profiles'];
    return PaymentTransaction(
      id: entry['id']?.toString() ?? '',
      customerId: customer.id,
      customerName: customer.businessName,
      amount: amount,
      discount: discount,
      amountReceived: entry['is_bounced'] == true
          ? 0
          : (entry['amount_received'] as num?)?.toDouble() ??
                (amount - discount),
      previousBalance:
          (entry['balance_before'] as num?)?.toDouble() ??
          (entry['previous_balance'] as num?)?.toDouble() ??
          0,
      remainingBalance:
          (entry['balance_after'] as num?)?.toDouble() ??
          (entry['remaining_balance'] as num?)?.toDouble() ??
          0,
      transactionDate:
          DateTime.tryParse(entry['transaction_date']?.toString() ?? '') ??
          DateTime.now(),
      createdAt: DateTime.tryParse(entry['created_at']?.toString() ?? ''),
      notes: entry['notes']?.toString() ?? '',
      signature: Uint8List(0),
      signaturePath: entry['signature_path']?.toString(),
      receivedBy: profile is Map
          ? profile['name']?.toString() ?? 'Salesman'
          : 'Salesman',
      paymentMethod: entry['payment_method']?.toString() ?? 'cash',
      paymentMethodNote: entry['payment_method_note']?.toString() ?? '',
      transactionType: 'payment_received',
    );
  }

  /// A receipt is still worth sending when the signature cannot be loaded.
  static Future<Uint8List?> _signature(PaymentTransaction payment) async {
    final path = payment.signaturePath;
    if (path == null || path.isEmpty) return null;
    try {
      return await TransactionService.downloadSignature(path);
    } catch (error) {
      debugPrint('Receipt made without its signature: $error');
      return null;
    }
  }

  /// WhatsApp and WhatsApp Business, whichever are on this phone.
  static Future<List<String>> installedApps() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
    try {
      return await channel.invokeListMethod<String>('whatsAppApps') ?? [];
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
    }
  }

  static String appName(String app) => _appNames[app] ?? app;

  static Future<String?> preferredApp() async =>
      (await SharedPreferences.getInstance()).getString(_appPreference);

  static Future<void> setPreferredApp(String app) async =>
      (await SharedPreferences.getInstance()).setString(_appPreference, app);

  /// True when WhatsApp opened, false to use the share menu instead, and null
  /// when the person backed out.
  static Future<bool?> _sendOnAndroid(
    BuildContext context,
    String number,
    Uint8List image,
    String name,
  ) async {
    final apps = await installedApps();
    if (apps.isEmpty || !context.mounted) return false;
    var app = apps.first;
    if (apps.length > 1) {
      final saved = await preferredApp();
      if (!context.mounted) return null;
      if (saved != null && apps.contains(saved)) {
        app = saved;
      } else {
        final chosen = await _chooseApp(context, apps);
        if (chosen == null) return null;
        await setPreferredApp(chosen);
        app = chosen;
      }
    }
    try {
      return await channel.invokeMethod<bool>('sendToWhatsApp', {
            'app': app,
            'phone': number,
            'image': image,
            'name': name,
          }) ??
          false;
    } on PlatformException catch (error) {
      debugPrint('Could not hand the receipt to WhatsApp: $error');
      return false;
    }
  }

  static Future<String?> _chooseApp(BuildContext context, List<String> apps) =>
      showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Send receipts from',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              for (final app in apps)
                ListTile(
                  leading: const Icon(Icons.chat_outlined),
                  title: Text(appName(app)),
                  onTap: () => Navigator.pop(sheetContext, app),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Text(
                  'You can change this later in My profile.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      );

  /// Windows apps cannot attach a file to a chat, so the receipt is copied
  /// and the person pastes it. Returns as [_sendOnAndroid] does.
  static Future<bool?> _sendOnWindows(
    BuildContext context,
    Customer customer,
    String number,
    Uint8List image,
  ) async {
    if (!await _copyImage(image)) return false;
    if (!context.mounted) return null;
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Send to ${customer.businessName}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The receipt is copied. WhatsApp opens at +$number: '
                'press Ctrl+V in the chat, then Send.',
              ),
              const SizedBox(height: 14),
              Flexible(
                child: Center(child: Image.memory(image, fit: BoxFit.contain)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open WhatsApp'),
          ),
        ],
      ),
    );
    if (go != true) return null;
    await _openChat(number);
    return true;
  }

  static Future<bool> _copyImage(Uint8List png) async {
    try {
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      final pixels = await image.toByteData();
      final size = (image.width, image.height);
      image.dispose();
      codec.dispose();
      if (pixels == null) return false;
      return await channel.invokeMethod<bool>('copyImage', {
            'png': png,
            'rgba': pixels.buffer.asUint8List(),
            'width': size.$1,
            'height': size.$2,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The device's own share menu, when WhatsApp cannot be opened directly.
  static Future<void> _share(
    BuildContext context,
    Uint8List image,
    String name,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        title: 'Payment receipt',
        files: [XFile.fromData(image, mimeType: 'image/png')],
        // XFile.fromData's name is ignored on most platforms. Keep the
        // PNG extension on the actual shared file so WhatsApp opens it as
        // an image. The receipt already contains all caption information.
        fileNameOverrides: [name],
        sharePositionOrigin: box != null && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      ),
    );
  }
}
