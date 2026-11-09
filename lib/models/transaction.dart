import 'dart:typed_data';

/// A single entry in the business ledger.
///
/// [transactionType] should be one of: 'sale', 'payment_received',
/// or 'sales_return'. Keep these values consistent throughout the app.
class PaymentTransaction {
  final String id;
  final String customerId;
  final String customerName;
  final double amount;
  final double discount;
  final double amountReceived;
  final double previousBalance;
  final double remainingBalance;
  final DateTime transactionDate;

  /// When this row was actually entered, independent of its business date.
  final DateTime? createdAt;
  final String notes;
  final Uint8List signature;
  final String? signaturePath;

  /// Name of the person who collected the payment, when applicable.
  final String receivedBy;

  /// Authenticated user who saved this payment, when available.
  final String? enteredBy;

  /// Examples: 'cash', 'cheque', 'net_banking', or 'gpay'.
  final String paymentMethod;

  /// Extra payment-method details, such as a cheque number.
  final String paymentMethodNote;

  /// A cheque that bounced is not money actually received.
  final bool isBounced;
  final bool isHiddenFromLedger;

  /// Ledger transaction type: 'sale', 'payment_received', or 'sales_return'.
  ///
  /// Defaults to 'unknown' so existing records are not incorrectly labelled
  /// as payments. The sale, payment, and return flows should explicitly set
  /// the correct type as those files are updated.
  final String transactionType;

  PaymentTransaction({
    required this.id,
    required this.customerId,
    required this.customerName,
    required this.amount,
    this.discount = 0,
    double? amountReceived,
    required this.previousBalance,
    required this.remainingBalance,
    required this.transactionDate,
    this.createdAt,
    required this.notes,
    required this.signature,
    this.signaturePath,
    this.receivedBy = 'Unknown',
    this.enteredBy,
    this.paymentMethod = 'cash',
    this.paymentMethodNote = '',
    this.isBounced = false,
    this.isHiddenFromLedger = false,
    this.transactionType = 'unknown',
  }) : amountReceived = amountReceived ?? (amount - discount);

  /// Net money collected after removing the discount given to the customer.
  /// Use the persisted net amount when available. The constructor derives it
  /// from amount minus discount only for legacy rows without that field.
  double get actualAmountReceived =>
      isBounced ? 0 : amountReceived.clamp(0, double.infinity).toDouble();

  String get reference {
    final compact = id.replaceAll('-', '').toUpperCase();
    final suffix = compact.length > 10 ? compact.substring(0, 10) : compact;
    return 'TXN-$suffix';
  }
}
