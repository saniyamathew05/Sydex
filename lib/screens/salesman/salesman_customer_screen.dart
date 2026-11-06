import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/customer.dart';
import '../../services/customer_service.dart';

import '../../models/transaction.dart';

import '../payments/payment_screen.dart';
import '../../services/business_date_service.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/salesman_visit_service.dart';
import '../../services/ledger_user_name_service.dart';
import '../../services/payment_receipt_share_service.dart';

class SalesmanCustomerDetailsScreen extends StatefulWidget {
  final Customer customer;

  const SalesmanCustomerDetailsScreen({super.key, required this.customer});

  @override
  State<SalesmanCustomerDetailsScreen> createState() =>
      _SalesmanCustomerDetailsScreenState();
}

class _SalesmanCustomerDetailsScreenState
    extends State<SalesmanCustomerDetailsScreen> {
  List<Map<String, dynamic>> _ledgerEntries = const [];
  String _historyFilter = 'All';
  bool _preparingReceiptShare = false;
  late Customer _customer;
  bool _savingPhone = false;

  List<Map<String, dynamic>> get _saleEntries => _ledgerEntries
      .where((entry) => entry['entry_type']?.toString() == 'purchase')
      .toList();

  List<Map<String, dynamic>> get _returnEntries =>
      _ledgerEntries.where((entry) {
        final type = entry['entry_type']?.toString().toLowerCase();
        return type == 'return' || type == 'sales_return';
      }).toList();

  List<Map<String, dynamic>> get _refusalEntries => _ledgerEntries
      .where((entry) => entry['entry_type']?.toString() == 'refusal')
      .toList();

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
    _loadCustomerHistory();
  }

  Future<void> _loadCustomerHistory() async {
    await Future.wait([
      TransactionService.loadTransactions(),
      _loadSaleHistory(),
    ]);
  }

  Future<void> _loadSaleHistory() async {
    final entries = await TransactionService.getCustomerLedger(
      _customer.id,
      openingBalance: _customer.openingBalance,
    );
    try {
      final names = await LedgerUserNameService.loadNames(
        entries.map((entry) => entry['user_id']?.toString()),
      );
      for (final entry in entries) {
        final name = names[entry['user_id']?.toString()];
        if (name != null) entry['profiles'] = {'name': name};
      }
    } catch (error) {
      debugPrint('Could not load transaction author names: $error');
    }
    try {
      final refusals = await Supabase.instance.client
          .from('salesman_customer_daily_status')
          .select('id, status_date, created_at, note')
          .eq('customer_id', _customer.id)
          .eq('status', 'rejected')
          .order('status_date', ascending: false);
      entries.addAll(
        (refusals as List).map(
          (row) => <String, dynamic>{
            'id': 'refusal-${row['id']}',
            'entry_type': 'refusal',
            'transaction_date':
                row['created_at']?.toString() ??
                '${row['status_date']}T00:00:00',
            'status_date': row['status_date'],
            'notes': row['note']?.toString() ?? 'Customer refused payment',
            'amount': 0,
            'amount_received': 0,
          },
        ),
      );
    } catch (error) {
      debugPrint('Could not load refusal history: $error');
    }
    if (!mounted) return;
    setState(() => _ledgerEntries = entries);
  }

  Future<void> _editPhone() async {
    var phone = _customer.phone;
    final formKey = GlobalKey<FormState>();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit customer phone number'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Phone number'),
            onChanged: (value) => phone = value,
            validator: (value) {
              final text = (value ?? '').trim();
              final digits = text.replaceAll(RegExp(r'\D'), '');
              return !RegExp(r'^[+0-9 ()-]+$').hasMatch(text) ||
                      digits.length < 7 ||
                      digits.length > 15 ||
                      text.length > 40
                  ? 'Enter a valid phone number (7–15 digits)'
                  : null;
            },
            onFieldSubmitted: (_) {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, phone.trim());
              }
            },
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
                Navigator.pop(dialogContext, phone.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || !mounted || value == _customer.phone) return;
    setState(() => _savingPhone = true);
    final updated = await CustomerService.updateCustomerPhone(
      customerId: _customer.id,
      phone: value,
    );
    if (!mounted) return;
    setState(() {
      _savingPhone = false;
      if (updated != null) _customer = updated;
    });
    _showPhoneMessage(
      updated != null
          ? 'Phone number updated.'
          : CustomerService.errorMessage ?? 'Could not update phone number.',
    );
  }

  Future<void> _callCustomer() async {
    final phone = _customer.phone.trim();
    if (phone.isEmpty) {
      _showPhoneMessage('This customer has no phone number.');
      return;
    }
    final dialable = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    try {
      final launched = await launchUrl(Uri(scheme: 'tel', path: dialable));
      if (!launched && mounted) {
        _showPhoneMessage('Could not open the phone app.');
      }
    } catch (_) {
      if (mounted) _showPhoneMessage('Could not open the phone app.');
    }
  }

  Future<void> _messageOnWhatsApp() async {
    try {
      await PaymentReceiptShareService.openCustomerChat(_customer);
    } catch (error) {
      if (mounted) _showPhoneMessage('Could not open WhatsApp: $error');
    }
  }

  Future<void> _shareReceipt() async {
    if (_preparingReceiptShare) return;
    setState(() => _preparingReceiptShare = true);
    try {
      await PaymentReceiptShareService.shareLatest(
        context: context,
        customer: _customer,
      );
    } catch (error) {
      if (mounted) _showPhoneMessage('Could not share receipt: $error');
    } finally {
      if (mounted) setState(() => _preparingReceiptShare = false);
    }
  }

  Widget _buildCombinedHistory() {
    final entries = List<Map<String, dynamic>>.from(_ledgerEntries)
      ..sort((a, b) {
        final aDate = DateTime.tryParse(
          a['transaction_date']?.toString() ?? '',
        );
        final bDate = DateTime.tryParse(
          b['transaction_date']?.toString() ?? '',
        );
        if (aDate == null && bDate == null) return 0;
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        return bDate.compareTo(aDate);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        const Text(
          'All History',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (entries.isEmpty)
          const Text('No history recorded yet.')
        else
          ...entries.map(_buildCombinedHistoryEntry),
      ],
    );
  }

  Widget _buildCombinedHistoryEntry(Map<String, dynamic> entry) {
    final type = entry['entry_type']?.toString().toLowerCase() ?? '';
    final date = DateTime.tryParse(
      entry['transaction_date']?.toString() ?? '',
    )?.toLocal();
    final dateLabel = date == null
        ? ''
        : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
    final discount = (entry['discount'] as num?)?.toDouble() ?? 0;
    final amountReceived = entry['is_bounced'] == true
        ? 0.0
        : (entry['amount_received'] as num?)?.toDouble() ?? (amount - discount);
    final isRefusal = type == 'refusal';
    final isReturn = type == 'return' || type == 'sales_return';
    final isSale = type == 'purchase';
    final title = isRefusal
        ? 'Payment refused'
        : isReturn
        ? 'Sales return'
        : isSale
        ? 'Sale'
        : 'Payment received';
    final icon = isRefusal
        ? Icons.block_outlined
        : isReturn
        ? Icons.assignment_return_outlined
        : isSale
        ? Icons.point_of_sale_outlined
        : Icons.payments_outlined;
    final color = isRefusal
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isRefusal ? Theme.of(context).colorScheme.errorContainer : null,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isRefusal ? color : null,
          ),
        ),
        subtitle: Text(
          '${dateLabel.isEmpty ? 'Date unavailable' : dateLabel}${isRefusal ? '\n${entry['notes'] ?? 'Customer refused payment'}' : ''}',
        ),
        trailing: Text(
          isRefusal
              ? '—'
              : '${isSale || (!isReturn && !isSale) ? '+' : '-'} ${CurrencyFormatter.rupees(type == 'payment' ? amountReceived : amount)}',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isRefusal ? color : (isSale ? Colors.red : Colors.green),
          ),
        ),
      ),
    );
  }

  void _showPhoneMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _recordedBy(Map<String, dynamic> entry) {
    final profile = entry['profiles'];
    if (profile is Map) {
      final name = profile['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) return name;
    }
    return entry['user_id']?.toString() ==
            Supabase.instance.client.auth.currentUser?.id
        ? 'You'
        : 'Another team member';
  }

  Future<void> _recordSalesReturn(double currentBalance) async {
    final amountController = TextEditingController();
    final notesController = TextEditingController();
    var selectedDate = BusinessDateService.selectedDate.value;
    var isSaving = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Return Products'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    CurrencyFormatter.customerBalance(currentBalance),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: amountController,
                  enabled: !isSaving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Return amount',
                    prefixText: '₹ ',
                    helperText:
                        'Excess return becomes credit owed to the customer.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: isSaving
                      ? null
                      : () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setDialogState(() {
                              selectedDate = DateTime(
                                picked.year,
                                picked.month,
                                picked.day,
                              );
                            });
                          }
                        },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Return date',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                    child: Text(
                      '${selectedDate.day.toString().padLeft(2, '0')}/'
                      '${selectedDate.month.toString().padLeft(2, '0')}/'
                      '${selectedDate.year}',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  enabled: !isSaving,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSaving
                  ? null
                  : () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: isSaving
                  ? null
                  : () async {
                      final amount = double.tryParse(
                        amountController.text.trim().replaceAll(',', ''),
                      );
                      if (amount == null || !amount.isFinite || amount <= 0) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text('Enter a valid return amount.'),
                          ),
                        );
                        return;
                      }
                      setDialogState(() => isSaving = true);
                      try {
                        await Supabase.instance.client.rpc(
                          'record_return',
                          params: {
                            'p_customer_id': _customer.id,
                            'p_amount': amount,
                            'p_notes': notesController.text.trim().isEmpty
                                ? null
                                : notesController.text.trim(),
                            'p_transaction_date': selectedDate
                                .toUtc()
                                .toIso8601String(),
                          },
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(true);
                        }
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() => isSaving = false);
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(
                            content: Text('Could not record return: $error'),
                          ),
                        );
                      }
                    },
              child: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Record return'),
            ),
          ],
        ),
      ),
    );

    amountController.dispose();
    notesController.dispose();
    if (saved != true || !mounted) return;

    // A sales return is still a completed customer visit. Record it as
    // handled today so the customer moves from Pending to Visited even when
    // no payment was collected.
    try {
      await SalesmanVisitService.recordStatus(
        customerId: _customer.id,
        status: 'paid',
        note: 'Sales return recorded',
      );
    } catch (error) {
      debugPrint('Could not record sales return visit status: $error');
    }

    await Future.wait([
      TransactionService.loadCustomerBalances(),
      _loadSaleHistory(),
    ]);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Sales return recorded.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Details')),

      body: ValueListenableBuilder<int>(
        valueListenable: TransactionService.dataVersion,

        builder: (context, _, _) {
          final cachedBalance = TransactionService.getCurrentBalance(
            customerId: _customer.id,

            openingBalance: _customer.openingBalance,
          );
          // Customer history is rebuilt chronologically from every visible
          // sale, payment, and return. Use that final ledger balance for the
          // amount-due card so it cannot disagree with the history cards or a
          // stale aggregate balance snapshot.
          final balance = _ledgerEntries.isNotEmpty
              ? ((_ledgerEntries.first['balance_after'] as num?)?.toDouble() ??
                    cachedBalance)
              : cachedBalance;

          final payments = TransactionService.getCustomerTransactions(
            _customer.id,
          );

          final effectivePayments = payments
              .where((payment) => !payment.isBounced)
              .toList(growable: false);
          final totalPaid = effectivePayments.fold(
            0.0,

            (sum, payment) => sum + payment.actualAmountReceived,
          );

          return RefreshIndicator(
            onRefresh: () async {
              await _loadCustomerHistory();

              if (mounted) {
                setState(() {});
              }
            },

            child: ListView(
              padding: const EdgeInsets.all(20),

              children: [
                // ------------------------------------------------

                // CUSTOMER HEADER

                // ------------------------------------------------
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    CircleAvatar(
                      radius: 30,

                      child: Text(
                        _getInitials(_customer.businessName),

                        style: const TextStyle(
                          fontSize: 20,

                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    const SizedBox(width: 14),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,

                        children: [
                          Text(
                            _customer.businessName,

                            style: const TextStyle(
                              fontSize: 24,

                              fontWeight: FontWeight.bold,
                            ),
                          ),

                          const SizedBox(height: 6),

                          Row(
                            children: [
                              const Icon(Icons.location_on_outlined, size: 17),

                              const SizedBox(width: 5),

                              Expanded(child: Text(_customer.location)),
                            ],
                          ),

                          const SizedBox(height: 4),

                          Row(
                            children: [
                              const Icon(Icons.phone_outlined, size: 17),

                              const SizedBox(width: 5),

                              Expanded(
                                child: Text(
                                  _customer.phone.isEmpty
                                      ? 'No phone number'
                                      : _customer.phone,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit phone number',
                                visualDensity: VisualDensity.compact,
                                onPressed: _savingPhone ? null : _editPhone,
                                icon: const Icon(Icons.edit_outlined, size: 19),
                              ),
                              IconButton(
                                tooltip: 'Call customer',
                                visualDensity: VisualDensity.compact,
                                onPressed: _customer.phone.trim().isEmpty
                                    ? null
                                    : _callCustomer,
                                icon: const Icon(Icons.call_outlined, size: 19),
                              ),
                              IconButton(
                                tooltip: 'Open customer WhatsApp chat',
                                visualDensity: VisualDensity.compact,
                                onPressed: _customer.phone.trim().isEmpty
                                    ? null
                                    : _messageOnWhatsApp,
                                icon: const Icon(Icons.chat_outlined, size: 19),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            onPressed: _preparingReceiptShare
                                ? null
                                : _shareReceipt,
                            icon: const Icon(
                              Icons.receipt_long_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _preparingReceiptShare
                                  ? 'Preparing receipt…'
                                  : 'Share receipt',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // ------------------------------------------------

                // AMOUNT DUE CARD

                // ------------------------------------------------
                Container(
                  width: double.infinity,

                  padding: const EdgeInsets.all(22),

                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,

                    borderRadius: BorderRadius.circular(20),
                  ),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.account_balance_wallet_outlined,

                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),

                          const SizedBox(width: 8),

                          Text(
                            balance < 0 ? 'Owed to customer' : 'Amount Due',

                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,

                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      Text(
                        CurrencyFormatter.rupees(balance.abs()),

                        style: TextStyle(
                          fontSize: 32,

                          fontWeight: FontWeight.bold,

                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),

                      const SizedBox(height: 4),

                      Text(
                        balance < 0
                            ? 'Owed to customer'
                            : balance > 0
                            ? 'Outstanding amount'
                            : 'No outstanding balance',

                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer
                              .withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // ------------------------------------------------

                // QUICK PAYMENT BUTTON

                // ------------------------------------------------
                SizedBox(
                  width: double.infinity,

                  height: 54,

                  child: FilledButton.icon(
                    onPressed: balance <= 0
                        ? null
                        : () async {
                            final paymentSaved = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    PaymentScreen(customer: _customer),
                              ),
                            );
                            if (paymentSaved == true) {
                              try {
                                await SalesmanVisitService.recordStatus(
                                  customerId: _customer.id,
                                  status: 'paid',
                                );
                              } catch (error) {
                                debugPrint(
                                  'Could not record payment visit status: $error',
                                );
                              }
                              if (!mounted) return;
                              Navigator.pop(context, true);
                              return;
                            }

                            await TransactionService.loadTransactions();

                            if (mounted) {
                              setState(() {});
                            }
                          },

                    icon: const Icon(Icons.payments_outlined),

                    label: const Text(
                      'Receive Payment',

                      style: TextStyle(
                        fontSize: 16,

                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: () => _recordSalesReturn(balance),
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text('Record Sales Return'),
                  ),
                ),

                OutlinedButton.icon(
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Record no payment'),
                        content: Text(
                          'Confirm that ${_customer.businessName} did not pay today. Other salesmen will see this customer as handled for today.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('Confirm refusal'),
                          ),
                        ],
                      ),
                    );
                    if (confirm != true) return;
                    try {
                      await SalesmanVisitService.recordStatus(
                        customerId: _customer.id,
                        status: 'rejected',
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'No payment recorded. Other salesmen will see this customer as handled today.',
                            ),
                          ),
                        );
                        Navigator.pop(context, true);
                      }
                    } catch (error) {
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not record visit: $error'),
                          ),
                        );
                    }
                  },
                  icon: const Icon(Icons.person_off_outlined),
                  label: const Text('Record no payment today'),
                ),

                const SizedBox(height: 22),

                // ------------------------------------------------

                // STATISTICS

                // ------------------------------------------------
                Row(
                  children: [
                    Expanded(
                      child: _InfoCard(
                        icon: Icons.payments_outlined,

                        title: 'Total Paid',

                        value: CurrencyFormatter.rupees(totalPaid),
                      ),
                    ),

                    const SizedBox(width: 12),

                    Expanded(
                      child: _InfoCard(
                        icon: Icons.receipt_long_outlined,

                        title: 'Payments',

                        value: effectivePayments.length.toString(),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 28),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      [
                        'All',
                        'Sales',
                        'Payment',
                        'Payment Refused',
                        'Sales Return',
                      ].map((filter) {
                        return ChoiceChip(
                          label: Text(filter),
                          selected: _historyFilter == filter,
                          onSelected: (_) =>
                              setState(() => _historyFilter = filter),
                        );
                      }).toList(),
                ),

                if (_historyFilter == 'All') ...[_buildCombinedHistory()],

                if (_historyFilter == 'Sales') ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Sales History',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_saleEntries.isNotEmpty)
                        Text(
                          '${_saleEntries.length}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_saleEntries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No sales recorded yet.'),
                    )
                  else
                    ..._saleEntries.map((entry) {
                      final net = (entry['amount'] as num?)?.toDouble() ?? 0;
                      final discount =
                          (entry['discount'] as num?)?.toDouble() ?? 0;
                      final original = net + discount;
                      final balanceBefore =
                          (entry['balance_before'] as num?)?.toDouble() ?? 0;
                      final balanceAfter =
                          (entry['balance_after'] as num?)?.toDouble() ?? 0;
                      final date = DateTime.tryParse(
                        entry['transaction_date']?.toString() ?? '',
                      )?.toLocal();
                      final dateLabel = date == null
                          ? ''
                          : '${date.day.toString().padLeft(2, '0')}/'
                                '${date.month.toString().padLeft(2, '0')}/'
                                '${date.year}';
                      final notes = entry['notes']?.toString().trim() ?? '';
                      final recordedBy = _recordedBy(entry);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _SalesmanSaleDetailsScreen(
                                customer: _customer,
                                entry: entry,
                                recordedBy: recordedBy,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.point_of_sale_outlined),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'Sale',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(dateLabel),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Original amount: ${CurrencyFormatter.rupees(original)}',
                                ),
                                Text(
                                  'Amount after discount: ${CurrencyFormatter.rupees(net)}',
                                ),
                                if (discount > 0)
                                  Text(
                                    'Discount: ${CurrencyFormatter.rupees(discount)}',
                                  ),
                                Text(
                                  'Balance: ${CurrencyFormatter.balanceAfter(balanceBefore)} → ${CurrencyFormatter.balanceAfter(balanceAfter)}',
                                ),
                                Text('Recorded by: $recordedBy'),
                                if (notes.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text('Notes: $notes'),
                                ],
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    'View full details  ›',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                ],

                // ------------------------------------------------

                // PAYMENT HISTORY

                // ------------------------------------------------
                if (_historyFilter == 'Payment') ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,

                    children: [
                      const Text(
                        'Payment History',

                        style: TextStyle(
                          fontSize: 21,

                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      if (payments.isNotEmpty)
                        Text(
                          '${payments.length}',

                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,

                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  if (payments.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(28),

                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),

                        borderRadius: BorderRadius.circular(16),
                      ),

                      child: Column(
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,

                            size: 42,

                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),

                          const SizedBox(height: 12),

                          const Text(
                            'No payments yet',

                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),

                          const SizedBox(height: 4),

                          Text(
                            'Payment history will appear here.',

                            textAlign: TextAlign.center,

                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...payments.map((payment) {
                      final ledgerEntry = _ledgerEntries.firstWhere(
                        (entry) => entry['id']?.toString() == payment.id,
                        orElse: () => <String, dynamic>{},
                      );
                      return _PaymentCard(
                        transaction: payment,
                        previousBalanceOverride:
                            (ledgerEntry['balance_before'] as num?)?.toDouble(),
                        remainingBalanceOverride:
                            (ledgerEntry['balance_after'] as num?)?.toDouble(),
                      );
                    }),
                ],

                if (_historyFilter == 'Payment Refused') ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Payment Refused',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                      if (_refusalEntries.isNotEmpty)
                        Text(
                          '${_refusalEntries.length}',
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_refusalEntries.isEmpty)
                    const Text('No refused payments recorded.')
                  else
                    ..._refusalEntries.map((entry) {
                      final date = DateTime.tryParse(
                        entry['transaction_date']?.toString() ?? '',
                      )?.toLocal();
                      final dateLabel = date == null
                          ? entry['status_date']?.toString() ?? ''
                          : '${date.day.toString().padLeft(2, '0')}/'
                                '${date.month.toString().padLeft(2, '0')}/'
                                '${date.year}';
                      final note = entry['notes']?.toString().trim() ?? '';
                      return Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                            child: Icon(
                              Icons.block_outlined,
                              color: Theme.of(context).colorScheme.onError,
                            ),
                          ),
                          title: Text(
                            'Payment refused',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            'Refused on $dateLabel${note.isEmpty ? '' : '\n$note'}',
                          ),
                        ),
                      );
                    }),
                ],

                if (_historyFilter == 'Sales Return') ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Sales Returns',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_returnEntries.isNotEmpty)
                        Text(
                          '${_returnEntries.length}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_returnEntries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No sales returns recorded.'),
                    )
                  else
                    ..._returnEntries.map((entry) {
                      final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
                      final balanceBefore =
                          (entry['balance_before'] as num?)?.toDouble() ?? 0;
                      final balanceAfter =
                          (entry['balance_after'] as num?)?.toDouble() ?? 0;
                      final date = DateTime.tryParse(
                        entry['transaction_date']?.toString() ?? '',
                      )?.toLocal();
                      final dateLabel = date == null
                          ? ''
                          : '${date.day.toString().padLeft(2, '0')}/'
                                '${date.month.toString().padLeft(2, '0')}/'
                                '${date.year}';
                      final notes = entry['notes']?.toString().trim() ?? '';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.assignment_return_outlined),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Sales Return',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text(dateLabel),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Returned amount: ${CurrencyFormatter.rupees(amount)}',
                              ),
                              Text(
                                'Balance: ${CurrencyFormatter.balanceAfter(balanceBefore)} → ${CurrencyFormatter.balanceAfter(balanceAfter)}',
                              ),
                              Text('Recorded by: ${_recordedBy(entry)}'),
                              if (notes.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text('Notes: $notes'),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                ],
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));

    if (parts.isEmpty || parts.first.isEmpty) {
      return 'C';
    }

    if (parts.length == 1) {
      return parts.first[0].toUpperCase();
    }

    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

class _SalesmanSaleDetailsScreen extends StatefulWidget {
  const _SalesmanSaleDetailsScreen({
    required this.customer,
    required this.entry,
    required this.recordedBy,
  });

  final Customer customer;
  final Map<String, dynamic> entry;
  final String recordedBy;

  @override
  State<_SalesmanSaleDetailsScreen> createState() =>
      _SalesmanSaleDetailsScreenState();
}

class _SalesmanSaleDetailsScreenState
    extends State<_SalesmanSaleDetailsScreen> {
  Uint8List? _signature;
  bool _loadingSignature = false;
  bool _signatureLoaded = false;

  double _number(String key) => (widget.entry[key] as num?)?.toDouble() ?? 0;

  Future<void> _loadSignature() async {
    final path = widget.entry['signature_path']?.toString();
    if (path == null || path.isEmpty || _loadingSignature || _signatureLoaded) {
      return;
    }
    setState(() => _loadingSignature = true);
    final bytes = await TransactionService.downloadSignature(path);
    if (!mounted) return;
    setState(() {
      _signature = bytes;
      _loadingSignature = false;
      _signatureLoaded = true;
    });
  }

  String _dateLabel() {
    final date = DateTime.tryParse(
      widget.entry['transaction_date']?.toString() ?? '',
    )?.toLocal();
    if (date == null) return '—';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}  '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final net = _number('amount');
    final discount = _number('discount');
    final original = net + discount;
    final notes = entry['notes']?.toString().trim() ?? '';
    final method = entry['payment_method']?.toString().trim() ?? '';
    final methodNote = entry['payment_method_note']?.toString().trim() ?? '';
    final signaturePath = entry['signature_path']?.toString();
    final hasSignature = signaturePath != null && signaturePath.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Sale Details')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sale / Purchase',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(_dateLabel()),
                  const SizedBox(height: 18),
                  _SaleDetailRow(
                    label: 'Customer',
                    value: widget.customer.businessName,
                  ),
                  _SaleDetailRow(
                    label: 'Location',
                    value: widget.customer.location,
                  ),
                  if (widget.customer.phone.trim().isNotEmpty)
                    _SaleDetailRow(
                      label: 'Phone',
                      value: widget.customer.phone,
                    ),
                  _SaleDetailRow(
                    label: 'Recorded by',
                    value: widget.recordedBy,
                  ),
                  const Divider(height: 24),
                  _SaleDetailRow(
                    label: 'Original amount',
                    value: CurrencyFormatter.rupees(original),
                  ),
                  _SaleDetailRow(
                    label: 'Discount',
                    value: CurrencyFormatter.rupees(discount),
                  ),
                  _SaleDetailRow(
                    label: 'Amount after discount',
                    value: CurrencyFormatter.rupees(net),
                    emphasize: true,
                  ),
                  _SaleDetailRow(
                    label: 'Balance before',
                    value: CurrencyFormatter.rupees(_number('balance_before')),
                  ),
                  _SaleDetailRow(
                    label: 'Balance after',
                    value: CurrencyFormatter.rupees(_number('balance_after')),
                  ),
                  if (method.isNotEmpty)
                    _SaleDetailRow(label: 'Payment method', value: method),
                  if (methodNote.isNotEmpty)
                    _SaleDetailRow(
                      label: 'Payment method note',
                      value: methodNote,
                    ),
                ],
              ),
            ),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Notes',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(notes),
                  ],
                ),
              ),
            ),
          ],
          if (hasSignature) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Customer Signature',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    if (_signature != null)
                      Container(
                        width: double.infinity,
                        height: 180,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Image.memory(_signature!, fit: BoxFit.contain),
                      )
                    else if (_signatureLoaded)
                      const Text('Signature could not be loaded.')
                    else
                      OutlinedButton.icon(
                        onPressed: _loadingSignature ? null : _loadSignature,
                        icon: _loadingSignature
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.visibility_outlined),
                        label: Text(
                          _loadingSignature
                              ? 'Loading signature…'
                              : 'View signature',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SaleDetailRow extends StatelessWidget {
  const _SaleDetailRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
      color: emphasize ? Theme.of(context).colorScheme.primary : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value.isEmpty ? '—' : value,
              textAlign: TextAlign.end,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// INFO CARD

// ============================================================

class _InfoCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final String value;

  const _InfoCard({
    required this.icon,

    required this.title,

    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,

        borderRadius: BorderRadius.circular(16),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Icon(icon, size: 22),

          const SizedBox(height: 12),

          Text(
            value,

            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 3),

          Text(
            title,

            style: TextStyle(
              fontSize: 12,

              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// PAYMENT CARD

// ============================================================

class _PaymentCard extends StatefulWidget {
  final PaymentTransaction transaction;
  final double? previousBalanceOverride;
  final double? remainingBalanceOverride;

  const _PaymentCard({
    required this.transaction,
    this.previousBalanceOverride,
    this.remainingBalanceOverride,
  });

  @override
  State<_PaymentCard> createState() => _PaymentCardState();
}

class _PaymentCardState extends State<_PaymentCard> {
  Uint8List? signatureBytes;

  bool loadingSignature = false;

  bool signatureLoaded = false;

  Future<void> _loadSignature() async {
    if (signatureLoaded || loadingSignature) {
      return;
    }

    final path = widget.transaction.signaturePath;

    if (path == null || path.isEmpty) {
      setState(() {
        signatureLoaded = true;
      });

      return;
    }

    setState(() {
      loadingSignature = true;
    });

    final bytes = await TransactionService.downloadSignature(path);

    if (!mounted) {
      return;
    }

    setState(() {
      signatureBytes = bytes;

      loadingSignature = false;

      signatureLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final payment = widget.transaction;
    final previousBalance =
        widget.previousBalanceOverride ?? payment.previousBalance;
    final remainingBalance =
        widget.remainingBalanceOverride ?? payment.remainingBalance;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),

      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),

        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),

        leading: CircleAvatar(
          backgroundColor: Colors.green.withValues(alpha: 0.12),

          child: const Icon(Icons.check_circle_outline, color: Colors.green),
        ),

        title: Text(
          '+ ${CurrencyFormatter.rupees(payment.actualAmountReceived)}',

          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),

        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_formatDate(payment.transactionDate)),
            const SizedBox(height: 3),
            Text(
              'Method: ${_displayPaymentMethod(payment.paymentMethod)}'
              '${payment.paymentMethodNote.trim().isEmpty ? '' : ' • ${payment.paymentMethodNote.trim()}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),

        children: [
          const Divider(),

          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: _BalanceItem(
                  label: 'Previous',

                  value: CurrencyFormatter.rupees(previousBalance),
                ),
              ),

              Expanded(
                child: _BalanceItem(
                  label: 'Remaining',

                  value: CurrencyFormatter.balanceAfter(remainingBalance),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          _BalanceItem(
            label: 'Payment method',
            value: _displayPaymentMethod(payment.paymentMethod),
          ),

          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _BalanceItem(
                  label: 'Reference',
                  value: payment.reference,
                ),
              ),
              const SizedBox(width: 12),
              const Icon(
                Icons.cloud_done_outlined,
                size: 18,
                color: Colors.green,
              ),
              const SizedBox(width: 4),
              const Text(
                'Server confirmed',
                style: TextStyle(color: Colors.green, fontSize: 12),
              ),
            ],
          ),

          if (payment.paymentMethodNote.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            _BalanceItem(
              label: 'Method note',
              value: payment.paymentMethodNote.trim(),
            ),
          ],

          if (payment.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 16),

            Container(
              width: double.infinity,

              padding: const EdgeInsets.all(12),

              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,

                borderRadius: BorderRadius.circular(10),
              ),

              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  const Icon(Icons.notes_outlined, size: 19),

                  const SizedBox(width: 8),

                  Expanded(child: Text(payment.notes)),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          const Align(
            alignment: Alignment.centerLeft,

            child: Text(
              'Customer Signature',

              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),

          const SizedBox(height: 8),

          if (!signatureLoaded)
            SizedBox(
              width: double.infinity,

              child: OutlinedButton.icon(
                onPressed: loadingSignature ? null : _loadSignature,

                icon: loadingSignature
                    ? const SizedBox(
                        width: 18,

                        height: 18,

                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.visibility_outlined),

                label: Text(
                  loadingSignature ? 'Loading signature...' : 'View Signature',
                ),
              ),
            )
          else if (signatureBytes != null && signatureBytes!.isNotEmpty)
            Container(
              width: double.infinity,

              height: 150,

              decoration: BoxDecoration(
                color: Colors.white,

                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),

                borderRadius: BorderRadius.circular(10),
              ),

              padding: const EdgeInsets.all(10),

              child: Image.memory(signatureBytes!, fit: BoxFit.contain),
            )
          else
            Container(
              width: double.infinity,

              padding: const EdgeInsets.all(12),

              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,

                borderRadius: BorderRadius.circular(10),
              ),

              child: const Text('Signature unavailable.'),
            ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final localDate = date.toLocal();
    return '${localDate.day.toString().padLeft(2, '0')}/'
        '${localDate.month.toString().padLeft(2, '0')}/'
        '${localDate.year}  '
        '${localDate.hour.toString().padLeft(2, '0')}:'
        '${localDate.minute.toString().padLeft(2, '0')}';
  }

  String _displayPaymentMethod(String method) {
    final value = method.trim().replaceAll('_', ' ');
    if (value.isEmpty) return 'Not specified';
    return value
        .split(' ')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }
}

// ============================================================

// BALANCE ITEM

// ============================================================

class _BalanceItem extends StatelessWidget {
  final String label;

  final String value;

  const _BalanceItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Text(
          label,

          style: TextStyle(
            fontSize: 12,

            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: 4),

        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
