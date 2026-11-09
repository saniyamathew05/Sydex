import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/customer.dart';
import '../models/transaction.dart';
import 'payment_receipt_service.dart';
import 'transaction_service.dart';

/// Shared by owner and salesman customer details so both attach the receipt.
class PaymentReceiptShareService {
  static Future<void> openCustomerChat(Customer customer) async {
    final raw = customer.phone.trim();
    var phone = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.startsWith('00')) phone = phone.substring(2);
    // Local customer numbers use India's country code, as in the existing app.
    if (!raw.startsWith('+') && !raw.startsWith('00') && phone.length == 10) {
      phone = '91$phone';
    }
    if (phone.length < 7 || phone.length > 15) {
      throw StateError('Enter a valid customer phone number first.');
    }
    if (!await launchUrl(
      Uri.https('wa.me', '/$phone'),
      mode: LaunchMode.externalApplication,
    )) {
      throw StateError('Could not open WhatsApp.');
    }
  }

  static Future<void> shareLatest({
    required BuildContext context,
    required Customer customer,
  }) async {
    if (customer.phone.trim().isEmpty) {
      throw StateError('This customer has no phone number.');
    }
    final entries = await TransactionService.getCustomerLedger(
      customer.id,
      openingBalance: customer.openingBalance,
    );
    final payments = entries
        .where((entry) => entry['entry_type'] == 'payment')
        .toList();
    if (payments.isEmpty) {
      throw StateError('There is no payment receipt to share yet.');
    }
    DateTime enteredAt(Map<String, dynamic> entry) =>
        DateTime.tryParse(entry['created_at']?.toString() ?? '') ??
        DateTime.tryParse(entry['transaction_date']?.toString() ?? '') ??
        DateTime(0);
    payments.sort((a, b) => enteredAt(b).compareTo(enteredAt(a)));
    final entry = payments.first;
    final signaturePath = entry['signature_path']?.toString();
    if (signaturePath == null || signaturePath.isEmpty) {
      throw StateError('The latest payment has no saved signature.');
    }
    final signature = await TransactionService.downloadSignature(signaturePath);
    if (signature == null) {
      throw Exception('Could not load the payment signature.');
    }

    final transactionDate =
        DateTime.tryParse(entry['transaction_date']?.toString() ?? '') ??
        DateTime.now();
    final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
    final discount = (entry['discount'] as num?)?.toDouble() ?? 0;
    final profile = entry['profiles'];
    final receivedBy = profile is Map
        ? profile['name']?.toString() ?? 'Salesman'
        : 'Salesman';
    final payment = PaymentTransaction(
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
      transactionDate: transactionDate,
      createdAt: DateTime.tryParse(entry['created_at']?.toString() ?? ''),
      notes: entry['notes']?.toString() ?? '',
      signature: signature,
      signaturePath: signaturePath,
      receivedBy: receivedBy,
      paymentMethod: entry['payment_method']?.toString() ?? 'cash',
      paymentMethodNote: entry['payment_method_note']?.toString() ?? '',
      transactionType: 'payment_received',
    );
    final image = await PaymentReceiptService.buildReceiptImage(
      payment,
      signatureBytes: signature,
    );
    if (!context.mounted) return;
    final shouldShare = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Review payment receipt'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.memory(image, fit: BoxFit.contain),
                const SizedBox(height: 8),
                Text(
                  'Choose WhatsApp, then select ${customer.phone} '
                  'and review the receipt before sending.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Continue to share'),
          ),
        ],
      ),
    );
    if (shouldShare != true || !context.mounted) return;
    final shareBox = context.findRenderObject() as RenderBox?;
    final filename = 'payment-receipt-${payment.id}.png';
    await SharePlus.instance.share(
      ShareParams(
        title: 'Payment receipt',
        files: [XFile.fromData(image, mimeType: 'image/png')],
        // XFile.fromData's name is ignored on most platforms. Keep the
        // PNG extension on the actual shared file so WhatsApp opens it as
        // an image. The receipt already contains all caption information.
        fileNameOverrides: [filename],
        sharePositionOrigin: shareBox != null && shareBox.hasSize
            ? shareBox.localToGlobal(Offset.zero) & shareBox.size
            : null,
      ),
    );
  }
}
