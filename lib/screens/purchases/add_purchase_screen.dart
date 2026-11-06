import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/customer.dart';
import '../../services/customer_service.dart';
import '../../services/transaction_service.dart';
import '../../services/purchase_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/business_date_service.dart';
import '../../services/duplicate_transaction_service.dart';

class AddPurchaseScreen extends StatefulWidget {
  final Customer? initialCustomer;

  const AddPurchaseScreen({super.key, this.initialCustomer});

  @override
  State<AddPurchaseScreen> createState() => _AddPurchaseScreenState();
}

class _AddPurchaseScreenState extends State<AddPurchaseScreen> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _finalAmountController = TextEditingController();

  final TextEditingController _notesController = TextEditingController();

  Customer? _selectedCustomer;

  double _currentBalance = 0;

  bool _isSaving = false;
  bool _isLoadingBalance = false;

  DateTime _selectedDate = BusinessDateService.selectedDate.value;

  @override
  void initState() {
    super.initState();

    _selectedCustomer = widget.initialCustomer;

    if (_selectedCustomer != null) {
      _loadCurrentBalance();
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _finalAmountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentBalance() async {
    final customer = _selectedCustomer;

    if (customer == null) {
      return;
    }

    setState(() {
      _isLoadingBalance = true;
    });

    try {
      final balance = await TransactionService.getCurrentBalanceFromLedger(
        customerId: customer.id,
        openingBalance: customer.openingBalance,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _currentBalance = balance;
        _isLoadingBalance = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoadingBalance = false;
      });

      _showMessage('Could not load the current balance.', isError: true);
    }
  }

  Future<void> _selectCustomer() async {
    final selected = await showModalBottomSheet<Customer>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _CustomerSelectionSheet(
          customers: CustomerService.customers,
          selectedCustomer: _selectedCustomer,
        );
      },
    );

    if (selected == null) {
      return;
    }

    setState(() {
      _selectedCustomer = selected;
      _currentBalance = 0;
    });

    await _loadCurrentBalance();
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Select sale date',
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

  Future<void> _savePurchase() async {
    FocusScope.of(context).unfocus();

    final customer = _selectedCustomer;

    if (customer == null) {
      _showMessage('Please select a customer.', isError: true);
      return;
    }

    final amountText = _amountController.text.trim();

    final amount = double.tryParse(amountText);

    if (amount == null || amount <= 0) {
      _showMessage('Enter a valid purchase amount.', isError: true);
      return;
    }

    final finalAmountText = _finalAmountController.text.trim();
    final finalAmount = finalAmountText.isEmpty
        ? amount
        : double.tryParse(finalAmountText);
    if (finalAmount == null || finalAmount <= 0 || finalAmount > amount) {
      _showMessage(
        'Enter an amount after discount that is greater than zero and no more than the original amount.',
        isError: true,
      );
      return;
    }

    final discount = amount - finalAmount;

    final notes = _notesController.text.trim();

    final possibleDuplicate =
        await DuplicateTransactionService.findPossibleDuplicate(
      customerId: customer.id,
      entryType: 'purchase',
      amount: finalAmount,
      transactionDate: _selectedDate,
    );
    if (possibleDuplicate != null && mounted) {
      final saveAnyway = await _confirmPossibleDuplicate(
        customer.businessName,
        finalAmount,
        possibleDuplicate,
      );
      if (saveAnyway != true) return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await PurchaseService.recordPurchase(
        customerId: customer.id,
        amount: amount,
        discount: discount,
        notes: notes.isEmpty ? null : notes,
        transactionDate: _selectedDate,
      );

      await CustomerService.loadCustomers();
      await TransactionService.loadTransactions();

      if (!mounted) {
        return;
      }

      _showMessage('Sale added successfully.');

      Navigator.pop(context, true);
    } catch (error) {
      debugPrint('Failed to save sale: $error');
      if (!mounted) {
        return;
      }

      _showMessage(_friendlyError(error), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<bool?> _confirmPossibleDuplicate(
    String customerName,
    double amount,
    DuplicateTransactionCandidate candidate,
  ) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Possible duplicate sale'),
      content: Text(
        'A sale of ${CurrencyFormatter.rupees(amount)} for $customerName was recorded near this time.\n\n'
        'Existing entry: ${candidate.transactionDate?.toLocal().toString() ?? 'Unknown date'}',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Go back')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save anyway')),
      ],
    ),
  );

  String _friendlyError(Object error) {
    final message = error is PostgrestException
        ? error.message
        : error.toString();

    if (message.contains('Only an owner can record a purchase')) {
      return 'Only an owner can add sales.';
    }

    if (message.contains('Customer was not found') ||
        message.contains('selected customer was not found')) {
      return 'Customer was not found or is inactive.';
    }

    if (message.contains('Purchase amount must be greater than zero')) {
      return 'Sale amount must be greater than zero.';
    }

    if (message.contains('Discount must be less than')) {
      return 'The discount must be less than the original sale amount.';
    }

    if (message.contains('record_purchase_with_discount') ||
        message.contains('schema cache')) {
      return 'Sale saving is not available on this app version. Update the app and try again.';
    }

    if (error is PostgrestException && message.trim().isNotEmpty) {
      return 'Sale not saved: $message';
    }

    return 'Sale not saved: ${message.replaceFirst('Exception: ', '')}';
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : null,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final customer = _selectedCustomer;

    return Scaffold(
      backgroundColor: colorScheme.surface,

      appBar: AppBar(
        title: const Text(
          'New Sale',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 35),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 650),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // HEADER
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.orange.shade700,
                          Colors.orange.shade400,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.add_shopping_cart_rounded,
                            color: Colors.white,
                            size: 29,
                          ),
                        ),
                        const SizedBox(width: 15),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'New Sale',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 5),
                              Text(
                                'Record a new sale for this customer.',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  const Text(
                    'Customer',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    'Choose the customer whose account should be updated.',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),

                  const SizedBox(height: 16),

                  InkWell(
                    onTap: _isSaving ? null : _selectCustomer,
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: colorScheme.outline.withValues(alpha: 0.10),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(
                                alpha: 0.10,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              customer == null
                                  ? Icons.person_search_rounded
                                  : Icons.storefront_outlined,
                              color: colorScheme.primary,
                            ),
                          ),

                          const SizedBox(width: 13),

                          Expanded(
                            child: customer == null
                                ? const Text(
                                    'Select a customer',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        customer.businessName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.location_on_outlined,
                                            size: 14,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              customer.location,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                          ),

                          const SizedBox(width: 8),

                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (customer != null) ...[
                    const SizedBox(height: 16),

                    // CURRENT BALANCE
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(
                                alpha: 0.12,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.account_balance_wallet_outlined,
                              color: colorScheme.primary,
                            ),
                          ),

                          const SizedBox(width: 13),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _currentBalance < 0
                                      ? 'Customer Advance'
                                      : 'Current Amount Due',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                _isLoadingBalance
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: colorScheme.primary,
                                        ),
                                      )
                                    : Text(
                                        CurrencyFormatter.rupees(
                                          _currentBalance.abs(),
                                        ),
                                        style: TextStyle(
                                          fontSize: 25,
                                          fontWeight: FontWeight.w800,
                                          color: colorScheme.onPrimaryContainer,
                                        ),
                                      ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 28),

                  const Text(
                    'Sale Details',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    'Enter the original sale amount and the amount after discount.',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    enabled: !_isSaving,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Original Sale Amount',
                      hintText: '0.00',
                      prefixText: '₹ ',
                      prefixIcon: const Icon(Icons.payments_outlined),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: colorScheme.outline.withValues(alpha: 0.08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: Colors.orange.shade700,
                          width: 2,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextField(
                    controller: _finalAmountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    enabled: !_isSaving,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Amount After Discount',
                      hintText: '0.00',
                      prefixText: '₹ ',
                      prefixIcon: const Icon(Icons.payments_outlined),
                      helperText:
                          'Leave blank for no discount. Discount: ₹${((double.tryParse(_amountController.text.trim()) ?? 0) - (double.tryParse(_finalAmountController.text.trim().isEmpty ? _amountController.text.trim() : _finalAmountController.text.trim()) ?? 0)).clamp(0, double.infinity).toStringAsFixed(2)} · This amount is added to the balance.',
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: colorScheme.outline.withValues(alpha: 0.08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: Colors.orange.shade700,
                          width: 2,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  InkWell(
                    onTap: _isSaving ? null : _selectDate,
                    borderRadius: BorderRadius.circular(16),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Sale Date',
                        prefixIcon: const Icon(Icons.calendar_today_outlined),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color: colorScheme.outline.withValues(alpha: 0.08),
                          ),
                        ),
                      ),
                      child: Text(
                        _formatSelectedDate(),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextField(
                    controller: _notesController,
                    maxLines: 3,
                    enabled: !_isSaving,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Note',
                      hintText: 'Optional note about this sale',
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(bottom: 42),
                        child: Icon(Icons.notes_outlined),
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: colorScheme.outline.withValues(alpha: 0.08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: Colors.orange.shade700,
                          width: 2,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // INFO BOX
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 18,
                          color: Colors.orange.shade800,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This sale will increase the customer\'s outstanding balance.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 26),

                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _savePurchase,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
                      ),
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.add_shopping_cart_rounded),
                      label: Text(
                        _isSaving ? 'Saving Sale...' : 'Add Sale',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
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
// CUSTOMER SELECTION SHEET
// -----------------------------------------------------------------------------

class _CustomerSelectionSheet extends StatefulWidget {
  final List<Customer> customers;
  final Customer? selectedCustomer;

  const _CustomerSelectionSheet({
    required this.customers,
    this.selectedCustomer,
  });

  @override
  State<_CustomerSelectionSheet> createState() =>
      _CustomerSelectionSheetState();
}

class _CustomerSelectionSheetState extends State<_CustomerSelectionSheet> {
  final TextEditingController _searchController = TextEditingController();

  String _search = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final filteredCustomers = widget.customers.where((customer) {
      final query = _search.toLowerCase().trim();

      if (query.isEmpty) {
        return true;
      }

      return customer.businessName.toLowerCase().contains(query) ||
          customer.location.toLowerCase().contains(query) ||
          customer.phone.toLowerCase().contains(query);
    }).toList();

    return SafeArea(
      child: Container(
        constraints: const BoxConstraints(maxHeight: 650),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: colorScheme.outline.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
            ),

            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Select Customer',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),

            const SizedBox(height: 10),

            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (value) {
                setState(() {
                  _search = value;
                });
              },
              decoration: InputDecoration(
                hintText: 'Search customer...',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

            const SizedBox(height: 12),

            Flexible(
              child: filteredCustomers.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(35),
                      child: Column(
                        children: [
                          Icon(
                            Icons.search_off_rounded,
                            size: 42,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'No customers found.',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: filteredCustomers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 7),
                      itemBuilder: (context, index) {
                        final customer = filteredCustomers[index];

                        final selected =
                            customer.id == widget.selectedCustomer?.id;

                        final initial = customer.businessName.trim().isNotEmpty
                            ? customer.businessName.trim()[0].toUpperCase()
                            : '?';

                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.pop(context, customer),
                            borderRadius: BorderRadius.circular(15),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: selected
                                    ? colorScheme.primary.withValues(
                                        alpha: 0.08,
                                      )
                                    : colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: selected
                                      ? colorScheme.primary.withValues(
                                          alpha: 0.25,
                                        )
                                      : Colors.transparent,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary.withValues(
                                        alpha: 0.10,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        initial,
                                        style: TextStyle(
                                          color: colorScheme.primary,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 12),

                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          customer.businessName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${customer.location} • ${customer.phone}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  if (selected)
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: colorScheme.primary,
                                    )
                                  else
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
