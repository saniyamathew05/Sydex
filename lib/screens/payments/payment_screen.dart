import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:signature/signature.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/customer.dart';

import '../../models/transaction.dart';

import '../../services/customer_service.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/business_date_service.dart';
import '../../services/duplicate_transaction_service.dart';
import '../../services/payment_service.dart';

class PaymentScreen extends StatefulWidget {
  final Customer customer;

  const PaymentScreen({super.key, required this.customer});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  Color get emeraldForeground => Theme.of(context).brightness == Brightness.dark
      ? Colors.white
      : Colors.black;

  final TextEditingController _amountController = TextEditingController();

  final TextEditingController _discountController = TextEditingController(
    text: '0',
  );

  final TextEditingController _notesController = TextEditingController();

  final TextEditingController _paymentMethodNoteController =
      TextEditingController();

  String _paymentMethod = 'cash';

  final List<_PaymentMethodPart> _paymentParts = [
    _PaymentMethodPart('cash'),
    _PaymentMethodPart('gpay'),
  ];

  bool _splitPayment = false;
  bool _syncingSplitAmount = false;

  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,

    penColor: Colors.black,

    exportBackgroundColor: Colors.white,
  );

  double _currentBalance = 0;

  bool _isLoadingBalance = true;

  bool _isSaving = false;
  String? _paymentRequestKey;
  String? _paymentRequestSignaturePath;

  DateTime _selectedDate = BusinessDateService.selectedDate.value;

  @override
  void initState() {
    super.initState();

    _loadBalance();

    _amountController.addListener(_updatePreview);

    _discountController.addListener(_updatePreview);

    for (final part in _paymentParts) {
      part.amountController.addListener(_updateSplitTotal);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();

    _discountController.dispose();

    _notesController.dispose();
    _paymentMethodNoteController.dispose();

    for (final part in _paymentParts) {
      part.amountController.removeListener(_updateSplitTotal);
      part.amountController.dispose();
    }

    _signatureController.dispose();

    super.dispose();
  }

  Future<void> _loadBalance() async {
    setState(() {
      _isLoadingBalance = true;
    });

    final balance = await TransactionService.getCurrentBalanceFromLedger(
      customerId: widget.customer.id,

      openingBalance: widget.customer.openingBalance,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _currentBalance = balance;

      _isLoadingBalance = false;
    });
  }

  void _updatePreview() {
    if (mounted) {
      setState(() {});
    }
  }

  void _updateSplitTotal() {
    if (!mounted) return;
    if (_splitPayment && !_syncingSplitAmount) {
      final totalReceived = _enteredSplitTotal;
      final desiredSettlement = totalReceived + _discount;
      final current = _settlementAmount;
      if ((current - desiredSettlement).abs() >= 0.005) {
        _syncingSplitAmount = true;
        _amountController.text = desiredSettlement <= 0
            ? ''
            : desiredSettlement.toStringAsFixed(2);
        _amountController.selection = TextSelection.fromPosition(
          TextPosition(offset: _amountController.text.length),
        );
        _syncingSplitAmount = false;
      }
    }
    setState(() {});
  }

  double get _settlementAmount {
    return double.tryParse(_amountController.text.trim()) ?? 0;
  }

  double get _discount {
    return double.tryParse(_discountController.text.trim()) ?? 0;
  }

  double get _amountReceived {
    final result = _settlementAmount - _discount;

    if (result < 0) {
      return 0;
    }

    return result;
  }

  static const _paymentMethods = <String>['cash', 'cheque', 'neft', 'gpay'];

  void _setSplitPayment(bool enabled) {
    setState(() {
      _splitPayment = enabled;
      if (enabled && _paymentParts.length >= 2) {
        _paymentParts[0].method = _paymentMethod;
        if (_paymentParts[1].method == _paymentMethod) {
          _paymentParts[1].method = _paymentMethods.firstWhere(
            (method) => method != _paymentMethod,
          );
        }
      } else if (!enabled) {
        _paymentMethod = _paymentParts.first.method;
      }
    });
  }

  void _addPaymentPart() {
    final unusedMethods = _paymentMethods
        .where((method) => !_paymentParts.any((part) => part.method == method))
        .toList();
    if (unusedMethods.isEmpty) return;
    final part = _PaymentMethodPart(unusedMethods.first)
      ..amountController.addListener(_updateSplitTotal);
    setState(() => _paymentParts.add(part));
  }

  void _removePaymentPart(int index) {
    if (_paymentParts.length <= 2) return;
    setState(() {
      final part = _paymentParts.removeAt(index);
      part.amountController.removeListener(_updateSplitTotal);
      part.amountController.dispose();
    });
  }

  double get _enteredSplitTotal => _paymentParts.fold<double>(
    0,
    (total, part) =>
        total + (double.tryParse(part.amountController.text.trim()) ?? 0),
  );

  double get _remainingBalance {
    return _currentBalance - _settlementAmount;
  }

  void _setFullBalance() {
    _amountController.text = _currentBalance.toStringAsFixed(2);

    _amountController.selection = TextSelection.fromPosition(
      TextPosition(offset: _amountController.text.length),
    );

    setState(() {});
  }

  DateTime _paymentEntryDateTime(DateTime enteredAt) {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      enteredAt.hour,
      enteredAt.minute,
      enteredAt.second,
      enteredAt.millisecond,
      enteredAt.microsecond,
    );
  }

  void _clearSignature() {
    _signatureController.clear();

    setState(() {});
  }

  Future<void> _selectDate() async {
    final today = DateTime.now();

    final picked = await showDatePicker(
      context: context,

      initialDate: _selectedDate,

      firstDate: DateTime(2000),

      lastDate: DateTime(today.year, today.month, today.day),

      helpText: 'Select payment date',
    );

    if (picked == null || !mounted) {
      return;
    }

    setState(() {
      _selectedDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  String _formatSelectedDate() {
    final day = _selectedDate.day.toString().padLeft(2, '0');

    final month = _selectedDate.month.toString().padLeft(2, '0');

    return '$day/$month/${_selectedDate.year}';
  }

  Future<String?> _uploadSignature() async {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      _showMessage('You are not logged in.', isError: true);

      return null;
    }

    if (_signatureController.isEmpty) {
      _showMessage('Please collect the customer signature.', isError: true);

      return null;
    }

    final bytes = await _signatureController.toPngBytes();

    if (bytes == null || bytes.isEmpty) {
      _showMessage('Could not capture the signature.', isError: true);

      return null;
    }

    final paymentId = DateTime.now().microsecondsSinceEpoch.toString();

    final path = '${user.id}/$paymentId.png';

    try {
      await Supabase.instance.client.storage
          .from('payment-signatures')
          .uploadBinary(
            path,

            bytes,

            fileOptions: const FileOptions(
              contentType: 'image/png',

              upsert: false,
            ),
          );

      return path;
    } catch (error) {
      _showMessage('Could not upload the signature.', isError: true);

      return null;
    }
  }

  Future<void> _savePayment() async {
    FocusScope.of(context).unfocus();

    final amount = _settlementAmount;

    final discount = _discount;

    if (amount <= 0) {
      _showMessage('Enter the amount being settled.', isError: true);

      return;
    }

    if (discount < 0) {
      _showMessage('Discount cannot be negative.', isError: true);

      return;
    }

    if (discount >= amount) {
      _showMessage(
        'Discount must be less than the amount being settled.',

        isError: true,
      );

      return;
    }

    final received = amount - discount;

    if (received <= 0) {
      _showMessage('Amount received must be greater than zero.', isError: true);

      return;
    }

    final possibleDuplicate =
        await DuplicateTransactionService.findPossibleDuplicate(
          customerId: widget.customer.id,
          entryType: 'payment',
          amount: received,
          transactionDate: _selectedDate,
          paymentMethod: _paymentMethod,
        );
    if (possibleDuplicate != null && mounted) {
      final saveAnyway = await _confirmPossibleDuplicate(
        possibleDuplicate,
        received,
      );
      if (saveAnyway != true) return;
    }

    if (received >= 50000 || discount > 10000) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Review payment'),
          content: Text(
            'Please confirm ${CurrencyFormatter.rupees(received)} will be recorded for ${widget.customer.businessName}.\n\n'
            'Settlement: ${CurrencyFormatter.rupees(amount)}\n'
            'Discount: ${CurrencyFormatter.rupees(discount)}\n'
            'Method: ${_paymentMethodLabel(_paymentMethod)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm and save'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    var methodNote = _paymentMethodNoteController.text.trim();
    if (_splitPayment) {
      final usedMethods = _paymentParts.map((part) => part.method).toSet();
      if (usedMethods.length != _paymentParts.length) {
        _showMessage(
          'Choose a different method for each amount.',
          isError: true,
        );
        return;
      }
      final amounts = <({String method, double amount})>[];
      for (final part in _paymentParts) {
        final partAmount = double.tryParse(part.amountController.text.trim());
        if (partAmount == null || partAmount <= 0) {
          _showMessage(
            'Enter a positive amount for every payment method.',
            isError: true,
          );
          return;
        }
        amounts.add((method: part.method, amount: partAmount));
      }
      final splitTotal = amounts.fold<double>(
        0,
        (sum, part) => sum + part.amount,
      );
      if ((splitTotal - received).abs() >= 0.01) {
        _showMessage(
          'The method amounts must add up to ${CurrencyFormatter.rupees(received)}.',
          isError: true,
        );
        return;
      }
      _paymentMethod = amounts.first.method;
      final breakdown =
          'Split amounts: ${amounts.map((part) => '${part.method}=${part.amount.toStringAsFixed(2)}').join(';')}';
      methodNote = methodNote.isEmpty ? breakdown : '$breakdown • $methodNote';
    }

    if (_signatureController.isEmpty) {
      _showMessage('Please collect the customer signature.', isError: true);

      return;
    }

    // Capture this on the device when Save is pressed. Signature upload and
    // server processing can take long enough to skew a server-generated time.
    final enteredAt = DateTime.now();

    setState(() {
      _isSaving = true;
    });

    // Keep this key until the server confirms success. If a request times out,
    // the same submission can be retried without creating a second payment.
    _paymentRequestKey ??= PaymentService.createPaymentRequestKey();

    String? signaturePath;

    try {
      signaturePath = _paymentRequestSignaturePath ?? await _uploadSignature();

      if (signaturePath == null) {
        return;
      }
      _paymentRequestSignaturePath ??= signaturePath;

      final temporaryTransaction = PaymentTransaction(
        id: DateTime.now().microsecondsSinceEpoch.toString(),

        customerId: widget.customer.id,

        customerName: widget.customer.businessName,

        amount: amount,

        previousBalance: _currentBalance,

        remainingBalance: _remainingBalance,

        transactionDate: _paymentEntryDateTime(enteredAt),

        createdAt: enteredAt,

        notes: _notesController.text.trim(),

        paymentMethod: _paymentMethod,

        paymentMethodNote: methodNote,

        signature: await _signatureController.toPngBytes() ?? Uint8List(0),

        signaturePath: signaturePath,
      );

      final savedPayment = await _savePaymentWithDiscount(
        temporaryTransaction,

        discount,
      );

      if (savedPayment == null) {
        // Do not delete the signature here. The network result may be unknown
        // even when the server committed the payment. Keeping both this path
        // and the request key lets the next save attempt resolve safely.
        return;
      }

      await CustomerService.loadCustomers();

      await TransactionService.loadTransactions();

      if (!mounted) {
        return;
      }

      _showMessage(
        'Payment saved. ${CurrencyFormatter.rupees(received)} received.'
        ' WhatsApp receipt delivery is queued automatically when enabled.',
      );

      _paymentRequestKey = null;
      _paymentRequestSignaturePath = null;

      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        _showMessage('Could not save the payment.', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<bool?> _confirmPossibleDuplicate(
    DuplicateTransactionCandidate candidate,
    double amount,
  ) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Possible duplicate payment'),
      content: Text(
        'A payment of ${CurrencyFormatter.rupees(amount)} for this customer was recorded near this time.\n\n'
        'Existing entry: ${candidate.transactionDate?.toLocal().toString() ?? 'Unknown date'}'
        '${candidate.paymentMethod == null ? '' : '\nMethod: ${_paymentMethodLabel(candidate.paymentMethod!)}'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Go back'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save anyway'),
        ),
      ],
    ),
  );

  Future<PaymentTransaction?> _savePaymentWithDiscount(
    PaymentTransaction transaction,

    double discount,
  ) async {
    try {
      final selectedPaymentMethod = transaction.paymentMethod
          .trim()
          .toLowerCase();

      const allowedPaymentMethods = {'cash', 'cheque', 'neft', 'gpay'};

      if (!allowedPaymentMethods.contains(selectedPaymentMethod)) {
        throw Exception('Invalid payment method selected.');
      }

      final response = await Supabase.instance.client.rpc(
        'record_payment_idempotent',

        params: {
          'p_customer_id': transaction.customerId,

          'p_amount': transaction.amount,

          'p_discount': discount,

          'p_notes': transaction.notes.isEmpty ? null : transaction.notes,

          'p_signature_path': transaction.signaturePath,

          'p_transaction_date': transaction.transactionDate
              .toUtc()
              .toIso8601String(),
          'p_payment_method': selectedPaymentMethod,

          'p_payment_method_note': transaction.paymentMethodNote.isEmpty
              ? null
              : transaction.paymentMethodNote,
          'p_entered_at': (transaction.createdAt ?? DateTime.now())
              .toUtc()
              .toIso8601String(),
          'p_idempotency_key': _paymentRequestKey,
        },
      );

      final inserted = Map<String, dynamic>.from(response as Map);

      final savedTransaction = PaymentTransaction(
        id: inserted['id'] as String,

        customerId: inserted['customer_id'] as String,

        customerName: transaction.customerName,

        amount: (inserted['amount'] as num).toDouble(),

        discount: (inserted['discount'] as num?)?.toDouble() ?? discount,

        amountReceived: (inserted['amount_received'] as num?)?.toDouble(),

        previousBalance: (inserted['previous_balance'] as num).toDouble(),

        remainingBalance: (inserted['remaining_balance'] as num).toDouble(),

        transactionDate: DateTime.parse(inserted['transaction_date'] as String),

        createdAt: inserted['created_at'] == null
            ? transaction.createdAt
            : DateTime.parse(inserted['created_at'] as String),

        notes: (inserted['notes'] as String?) ?? '',

        paymentMethod:
            inserted['payment_method']?.toString() ?? selectedPaymentMethod,

        paymentMethodNote:
            inserted['payment_method_note']?.toString() ??
            _paymentMethodNoteController.text.trim(),

        signature: transaction.signature,

        signaturePath: inserted['signature_path'] as String?,

        transactionType: 'payment_received',
      );

      TransactionService.transactions.insert(0, savedTransaction);

      TransactionService.dataVersion.value++;

      return savedTransaction;
    } catch (error) {
      final message = error.toString();

      if (message.contains('Amount to settle cannot be greater')) {
        _showMessage(
          'Settlement amount is greater than the current balance.',

          isError: true,
        );
      } else if (message.contains('Discount must be less')) {
        _showMessage(
          'Discount must be less than the settlement amount.',

          isError: true,
        );
      } else {
        _showMessage(
          'Could not save the payment. Please try again.',

          isError: true,
        );
      }

      return null;
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),

        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  Widget _transactionDateSummary(
    BuildContext context, {
    required String label,
    required String value,
    required VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w800, fontSize: 16)),
            ])),
            Icon(Icons.edit_calendar_outlined, color: scheme.primary, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final received = _amountReceived;
    final remaining = _remainingBalance;
    final emerald = colors.primary;
    final emeraldLight = colors.secondary;

    final fieldFill = isDark
        ? const Color(0xFF071B12)
        : const Color(0xFFF7F9F8);
    final cardColor = isDark ? const Color(0xFF0D2A1D) : Colors.white;
    final hasCustomerPhone = widget.customer.phone
        .replaceAll(RegExp(r'\D'), '')
        .isNotEmpty;

    InputDecoration fieldDecoration({
      String? labelText,
      String? prefixText,
      String? hintText,
      Widget? prefixIcon,
      Widget? suffixIcon,
      String? helperText,
    }) {
      return InputDecoration(
        labelText: labelText,
        prefixText: prefixText,
        hintText: hintText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        helperText: helperText,
        filled: true,
        fillColor: fieldFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: isDark ? const Color(0xFF2A3532) : const Color(0xFFE2EDE4),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: emerald, width: 1.5),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text(
          'Record Payment',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: colors.primary,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _transactionDateSummary(
                    context,
                    label: 'Payment date',
                    value: _formatSelectedDate(),
                    onTap: _isSaving ? null : _selectDate,
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF173729)
                            : const Color(0xFFE2EDE4),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.16 : 0.05,
                          ),
                          blurRadius: 18,
                          offset: const Offset(0, 7),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: emerald.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            widget.customer.businessName.isNotEmpty
                                ? widget.customer.businessName[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: emerald,
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.customer.businessName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Icon(
                                    Icons.location_on_outlined,
                                    size: 15,
                                    color: colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      widget.customer.location,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          isDark ? const Color(0xFF06452C) : emerald,
                          isDark ? const Color(0xFF06452C) : emeraldLight,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: emerald.withValues(alpha: 0.22),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          _currentBalance < 0
                              ? 'Customer Advance'
                              : 'Current Amount Due',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 7),
                        _isLoadingBalance
                            ? const SizedBox(
                                width: 27,
                                height: 27,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                CurrencyFormatter.rupees(_currentBalance.abs()),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 31,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  const Text(
                    'Amount to Settle',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: fieldDecoration(
                      prefixText: '₹ ',
                      hintText: '0.00',
                      suffixIcon: TextButton(
                        onPressed: _setFullBalance,
                        child: Text(
                          'FULL',
                          style: TextStyle(
                            color: emerald,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Discount / Amount Forgiven',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _discountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: fieldDecoration(
                      prefixText: '₹ ',
                      hintText: '0.00',
                      helperText: 'Enter 0 if there is no discount.',
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Payment Method',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  if (!_splitPayment)
                    DropdownButtonFormField<String>(
                      initialValue: _paymentMethod,
                      decoration: fieldDecoration(
                        prefixIcon: const Icon(
                          Icons.account_balance_wallet_outlined,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'cash', child: Text('Cash')),
                        DropdownMenuItem(
                          value: 'cheque',
                          child: Text('Cheque / Check'),
                        ),
                        DropdownMenuItem(
                          value: 'neft',
                          child: Text('Online - NEFT'),
                        ),
                        DropdownMenuItem(
                          value: 'gpay',
                          child: Text('Online - GPay'),
                        ),
                      ],
                      onChanged: _isSaving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _paymentMethod = value);
                            },
                    ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Split across payment methods'),
                    value: _splitPayment,
                    onChanged: _isSaving ? null : _setSplitPayment,
                  ),
                  if (_splitPayment) ...[
                    for (
                      var index = 0;
                      index < _paymentParts.length;
                      index++
                    ) ...[
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _paymentParts[index].method,
                              decoration: fieldDecoration(
                                labelText: 'Method ${index + 1}',
                              ),
                              items: _paymentMethods
                                  .where(
                                    (method) =>
                                        method == _paymentParts[index].method ||
                                        !_paymentParts.any(
                                          (part) => part.method == method,
                                        ),
                                  )
                                  .map(
                                    (method) => DropdownMenuItem(
                                      value: method,
                                      child: Text(_paymentMethodLabel(method)),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _isSaving
                                  ? null
                                  : (value) {
                                      if (value == null) return;
                                      setState(
                                        () =>
                                            _paymentParts[index].method = value,
                                      );
                                    },
                            ),
                          ),
                          if (_paymentParts.length > 2)
                            IconButton(
                              tooltip: 'Remove method',
                              onPressed: _isSaving
                                  ? null
                                  : () => _removePaymentPart(index),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _paymentParts[index].amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: fieldDecoration(
                          labelText:
                              'Amount through ${_paymentMethodLabel(_paymentParts[index].method)} (₹)',
                          hintText: 'Enter this method’s amount',
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_paymentParts.length < _paymentMethods.length)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _isSaving ? null : _addPaymentPart,
                          icon: const Icon(Icons.add),
                          label: const Text('Add another method'),
                        ),
                      ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Amount received: ${CurrencyFormatter.rupees(_amountReceived)}',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Payment Method Note / Reference',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _paymentMethodNoteController,
                    maxLines: 2,
                    decoration: fieldDecoration(
                      hintText:
                          'Optional cheque number, NEFT reference, GPay note, etc.',
                    ),
                  ),
                  const SizedBox(height: 22),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(19),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF173729)
                            : const Color(0xFFE2EDE4),
                      ),
                    ),
                    child: Column(
                      children: [
                        _SummaryRow(
                          label: 'Amount to settle',
                          value:
                              '${CurrencyFormatter.rupees(_settlementAmount)}',
                        ),
                        const SizedBox(height: 11),
                        _SummaryRow(
                          label: 'Discount',
                          value: '${CurrencyFormatter.rupees(_discount)}',
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 5),
                          child: Divider(),
                        ),
                        _SummaryRow(
                          label: 'Amount actually received',
                          value: '${CurrencyFormatter.rupees(received)}',
                          bold: true,
                          valueColor: emerald,
                        ),
                        const SizedBox(height: 11),
                        _SummaryRow(
                          label: remaining < 0
                              ? 'Advance'
                              : 'Remaining balance',
                          value: '${CurrencyFormatter.rupees(remaining)}',
                          bold: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  const Text(
                    'Note',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _notesController,
                    maxLines: 3,
                    decoration: fieldDecoration(hintText: 'Optional note'),
                  ),
                  const SizedBox(height: 26),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Customer Signature',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Required',
                        style: TextStyle(
                          color: emerald,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 220,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF345245)
                            : const Color(0xFFE2EDE4),
                      ),
                      borderRadius: BorderRadius.circular(16),
                      color: emeraldForeground,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Signature(
                        controller: _signatureController,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _clearSignature,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Clear'),
                      style: TextButton.styleFrom(foregroundColor: emerald),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (hasCustomerPhone)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'If WhatsApp receipts are enabled and this customer has opted in, the receipt is queued automatically after saving.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _savePayment,
                      icon: _isSaving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(
                        _isSaving ? 'Saving...' : 'Save Payment',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: emerald,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------

// SUMMARY ROW

// -----------------------------------------------------------------------------

class _SummaryRow extends StatelessWidget {
  final String label;

  final String value;

  final bool bold;

  final Color? valueColor;

  const _SummaryRow({
    required this.label,

    required this.value,

    this.bold = false,

    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,

      children: [
        Expanded(
          child: Text(
            label,

            style: TextStyle(
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),

        const SizedBox(width: 15),

        Text(
          value,

          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,

            fontSize: bold ? 16 : 14,

            color: valueColor,
          ),
        ),
      ],
    );
  }
}

class _PaymentMethodPart {
  String method;
  final TextEditingController amountController = TextEditingController();

  _PaymentMethodPart(this.method);
}

String _paymentMethodLabel(String method) => switch (method) {
  'cash' => 'Cash',
  'cheque' => 'Cheque / Check',
  'neft' => 'Online - NEFT',
  'gpay' => 'Online - GPay',
  _ => method,
};
