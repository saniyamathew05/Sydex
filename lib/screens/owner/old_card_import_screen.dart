import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/old_card_import_service.dart';
import '../../services/currency_formatter.dart';

/// Owner-only workflow for extracting and reviewing transactions from one
/// customer's old handwritten card. This screen intentionally does not save
/// extracted entries to the live ledger.
class OldCardImportScreen extends StatefulWidget {
  const OldCardImportScreen({super.key});

  @override
  State<OldCardImportScreen> createState() => _OldCardImportScreenState();
}

class _OldCardImportScreenState extends State<OldCardImportScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _loadingCustomers = true;
  bool _extracting = false;
  bool _importing = false;
  String? _loadError;
  String? _selectedCustomerId;
  String? _selectedCustomerName;
  Map<String, dynamic>? _draft;
  List<Map<String, dynamic>> _customers = [];
  List<_EditableCardEntry> _entries = [];
  List<String> _warnings = [];
  String? _imageName;

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  Future<void> _loadCustomers() async {
    setState(() {
      _loadingCustomers = true;
      _loadError = null;
    });

    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('Please sign in again.');
      }

      final profile = await _supabase
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null || profile['role'] != 'owner') {
        throw Exception('Only the owner can import an old customer card.');
      }

      final rows = await _supabase
          .from('customers')
          .select('id, business_name, location')
          .eq('is_active', true)
          .order('business_name');

      _customers = (rows as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    } catch (error) {
      _loadError = _friendlyError(error);
    } finally {
      if (mounted) {
        setState(() => _loadingCustomers = false);
      }
    }
  }

  Future<void> _chooseCardImage() async {
    if (_selectedCustomerId == null || _extracting) return;

    try {
      const imageTypes = XTypeGroup(
        label: 'Card images',
        extensions: ['jpg', 'jpeg', 'png', 'webp'],
      );
      final file = await openFile(acceptedTypeGroups: [imageTypes]);
      if (file == null) return;

      final name = file.name;
      final lowerName = name.toLowerCase();
      final mimeType = lowerName.endsWith('.png')
          ? 'image/png'
          : lowerName.endsWith('.webp')
          ? 'image/webp'
          : 'image/jpeg';
      final bytes = await file.readAsBytes();

      setState(() {
        _extracting = true;
        _draft = null;
        _entries = [];
        _warnings = [];
        _imageName = name;
      });

      final result = await OldCardImportService.extractCard(
        customerId: _selectedCustomerId!,
        imageBytes: bytes,
        mimeType: mimeType,
      );

      final rawEntries = result['entries'];
      final parsedEntries = rawEntries is List
          ? rawEntries
                .whereType<Map>()
                .map(
                  (item) => _EditableCardEntry.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : <_EditableCardEntry>[];

      final rawWarnings = result['overallWarnings'];
      final warnings = rawWarnings is List
          ? rawWarnings.map((item) => item.toString()).toList()
          : <String>[];

      if (!mounted) return;
      setState(() {
        _draft = result;
        _entries = parsedEntries;
        _warnings = warnings;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyError(error))));
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  String? _validateEntries() {
    if (_selectedCustomerId == null) {
      return 'Select a customer first.';
    }
    if (_entries.isEmpty) {
      return 'There are no entries to import.';
    }
    if (_entries.length > 500) {
      return 'Import no more than 500 entries at a time.';
    }

    DateTime? previousDate;
    double? runningBalance;

    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      final number = i + 1;
      final dateText = entry.date.trim();
      final parsedDate = DateTime.tryParse(dateText);

      if (parsedDate == null ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText)) {
        return 'Entry $number needs a valid date in YYYY-MM-DD format.';
      }
      if (parsedDate.isAfter(DateTime.now())) {
        return 'Entry $number has a future date.';
      }
      if (previousDate != null && parsedDate.isBefore(previousDate)) {
        return 'Entries must be ordered from oldest to newest. Check entry $number.';
      }
      previousDate = parsedDate;

      if (!_allowedImportTypes.contains(entry.type)) {
        return 'Choose a transaction type for entry $number.';
      }

      final amount = double.tryParse(entry.amount.trim());
      if (amount == null || !amount.isFinite || amount <= 0) {
        return 'Entry $number must have an amount greater than zero.';
      }

      if (!_allowedMethods.contains(entry.paymentMethod)) {
        return 'Choose a valid payment method for entry $number.';
      }

      final balanceText = entry.writtenBalanceAfter.trim();
      double? writtenBalance;
      if (balanceText.isNotEmpty) {
        writtenBalance = double.tryParse(balanceText);
        if (writtenBalance == null ||
            !writtenBalance.isFinite ||
            writtenBalance < 0) {
          return 'Entry $number has an invalid written balance.';
        }
      }

      final effect = entry.type == 'sale' ? amount : -amount;

      if (i == 0) {
        if (writtenBalance == null) {
          return 'The first entry needs the balance written after it so the starting balance can be checked.';
        }
        runningBalance = writtenBalance - effect;
        if (runningBalance < -0.01) {
          return 'Entry 1 implies a negative starting balance. Correct its amount or written balance.';
        }
        runningBalance = runningBalance < 0 ? 0 : runningBalance;
        final calculated = runningBalance + effect;
        if ((calculated - writtenBalance).abs() > 0.01) {
          return 'Entry 1 does not match its written balance.';
        }
      } else {
        runningBalance = (runningBalance ?? 0) + effect;
        if (runningBalance < -0.01) {
          return 'Entry $number would make the customer balance negative. Check the transaction type, amount, and order.';
        }
        if (runningBalance < 0) runningBalance = 0;
        if (writtenBalance != null &&
            (writtenBalance - runningBalance).abs() > 0.01) {
          return 'Entry $number balance mismatch: calculated ${CurrencyFormatter.rupees(runningBalance)}, but the card says ${CurrencyFormatter.rupees(writtenBalance)}. Correct the entry before importing.';
        }
      }
    }
    return null;
  }

  Future<void> _validateAndConfirmImport() async {
    if (_importing) return;

    final validationError = _validateEntries();
    if (validationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm historical import'),
        content: Text(
          'You are about to import ${_entries.length} reviewed transactions for '
          '${_selectedCustomerName ?? 'this customer'}.\n\n'
          'This changes the customer ledger and sets its opening balance from '
          'the first card entry. The server will reject the import if this '
          'customer already has ledger transactions or if any running balance '
          'does not match.\n\n'
          'Only continue if you checked the dates, types, amounts, and balances.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Confirm import'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _importing = true);
    try {
      final result = await OldCardImportService.importReviewedEntries(
        customerId: _selectedCustomerId!,
        entries: _entries.map((entry) => entry.toJson()).toList(),
      );

      if (!mounted) return;
      final importedCount = result['importedCount'] ?? _entries.length;
      final startingBalance = result['startingBalance'];
      final endingBalance = result['endingBalance'];

      setState(() {
        _draft = null;
        _entries = [];
        _warnings = [];
        _imageName = null;
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline),
          title: const Text('Historical card imported'),
          content: Text(
            '$importedCount transactions were imported successfully.\n\n'
            'Starting balance: ${startingBalance == null ? '—' : CurrencyFormatter.rupees(num.tryParse(startingBalance.toString()) ?? 0)}\n'
            'Ending balance: ${endingBalance == null ? '—' : CurrencyFormatter.rupees(num.tryParse(endingBalance.toString()) ?? 0)}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyError(error)),
          duration: const Duration(seconds: 7),
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _resetReview() {
    setState(() {
      _draft = null;
      _entries = [];
      _warnings = [];
      _imageName = null;
    });
  }

  String _friendlyError(Object error) {
    var message = error.toString();
    message = message.replaceFirst('Exception: ', '');
    message = message.replaceFirst('FormatException: ', '');
    message = message.replaceFirst('PostgrestException(message: ', '');
    if (message.contains('GEMINI_API_KEY') ||
        message.contains('AI is not configured')) {
      return 'AI extraction is not configured yet. Add GEMINI_API_KEY to the Supabase Edge Function secrets, then try again.';
    }
    if (message.contains('Failed to fetch') ||
        message.contains('SocketException')) {
      return 'Could not reach the service. Check your internet connection and try again.';
    }
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Import Old Customer Card')),
      body: _loadingCustomers
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _buildErrorState()
          : RefreshIndicator(
              onRefresh: _loadCustomers,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _buildIntroCard(theme),
                  const SizedBox(height: 18),
                  _buildCustomerPicker(),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _selectedCustomerId == null || _extracting
                        ? null
                        : _chooseCardImage,
                    icon: _extracting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.document_scanner_outlined),
                    label: Text(
                      _extracting
                          ? 'Reading card…'
                          : 'Choose card photo and extract',
                    ),
                  ),
                  if (_imageName != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Selected image: $_imageName',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (_extracting) ...[
                    const SizedBox(height: 18),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text(
                      'Reading the handwriting. Nothing is being saved to the ledger.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_draft != null) ...[
                    const SizedBox(height: 24),
                    _buildReviewHeader(theme),
                    if (_warnings.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildWarnings(),
                    ],
                    const SizedBox(height: 12),
                    if (_entries.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No entries were detected. Try a clearer, well-lit photo.',
                          ),
                        ),
                      )
                    else
                      ..._entries.asMap().entries.map(
                        (entry) => _buildEntryCard(entry.key, entry.value),
                      ),
                    const SizedBox(height: 16),
                    _buildImportSummary(theme),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _entries.isEmpty || _extracting || _importing
                          ? null
                          : _validateAndConfirmImport,
                      icon: _importing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined),
                      label: Text(
                        _importing
                            ? 'Importing…'
                            : 'Validate & Import Reviewed Entries',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _importing ? null : _resetReview,
                      icon: const Icon(Icons.refresh),
                      label: const Text(
                        'Discard review and choose another card',
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 12),
            Text(_loadError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadCustomers,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.auto_awesome, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Turn a handwritten card into a reviewable draft',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Choose one customer, upload one card photo, and check every extracted sale, payment, return, and written balance. AI results can be wrong.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerPicker() {
    return DropdownButtonFormField<String>(
      initialValue: _selectedCustomerId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Customer',
        border: OutlineInputBorder(),
      ),
      items: _customers.map((customer) {
        final id = customer['id'].toString();
        final name = (customer['business_name'] ?? 'Unnamed customer')
            .toString();
        final location = (customer['location'] ?? '').toString();
        return DropdownMenuItem<String>(
          value: id,
          child: Text(
            location.isEmpty ? name : '$name · $location',
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: _extracting
          ? null
          : (value) {
              final selected = _customers.where(
                (customer) => customer['id'].toString() == value,
              );
              setState(() {
                _selectedCustomerId = value;
                _selectedCustomerName = selected.isEmpty
                    ? null
                    : (selected.first['business_name'] ?? '').toString();
                _draft = null;
                _entries = [];
                _warnings = [];
                _imageName = null;
              });
            },
    );
  }

  Widget _buildReviewHeader(ThemeData theme) {
    final cardName = (_draft?['customerNameOnCard'] ?? '').toString().trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Review extracted entries', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Selected customer: ${_selectedCustomerName ?? 'Unknown'}',
          style: theme.textTheme.bodyMedium,
        ),
        if (cardName.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Name written on card: $cardName'),
        ],
        const SizedBox(height: 8),
        Text(
          '${_entries.length} draft entr${_entries.length == 1 ? 'y' : 'ies'} · edit fields below before the import step',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildWarnings() {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.warning_amber_rounded),
                SizedBox(width: 8),
                Text('Please check these warnings'),
              ],
            ),
            const SizedBox(height: 8),
            ..._warnings.map(
              (warning) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $warning'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryCard(int index, _EditableCardEntry entry) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Entry ${index + 1}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (entry.needsReview)
                  const Chip(
                    avatar: Icon(Icons.edit_note, size: 18),
                    label: Text('Check carefully'),
                  ),
              ],
            ),
            if (entry.reviewReason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(entry.reviewReason, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            TextFormField(
              key: ValueKey('date-$index-${entry.date}'),
              initialValue: entry.date,
              decoration: const InputDecoration(
                labelText: 'Date (YYYY-MM-DD)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => entry.date = value,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _allowedTypes.contains(entry.type)
                  ? entry.type
                  : 'unknown',
              decoration: const InputDecoration(
                labelText: 'Transaction type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'sale', child: Text('New Sale')),
                DropdownMenuItem(
                  value: 'payment',
                  child: Text('Payment Received'),
                ),
                DropdownMenuItem(value: 'return', child: Text('Sales Return')),
                DropdownMenuItem(value: 'unknown', child: Text('Unknown')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => entry.type = value);
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey('amount-$index-${entry.amount}'),
              initialValue: entry.amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: false,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount (₹)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => entry.amount = value,
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey('balance-$index-${entry.writtenBalanceAfter}'),
              initialValue: entry.writtenBalanceAfter,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Balance written after this entry (₹)',
                helperText: 'Leave blank if the card does not show a balance.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => entry.writtenBalanceAfter = value,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _allowedMethods.contains(entry.paymentMethod)
                  ? entry.paymentMethod
                  : 'unknown',
              decoration: const InputDecoration(
                labelText: 'Payment method (if applicable)',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'unknown',
                  child: Text('Not noted / N/A'),
                ),
                DropdownMenuItem(value: 'cash', child: Text('Cash')),
                DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
                DropdownMenuItem(
                  value: 'neft',
                  child: Text('Net Banking (NEFT)'),
                ),
                DropdownMenuItem(value: 'gpay', child: Text('GPay')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => entry.paymentMethod = value);
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey('notes-$index-${entry.notes}'),
              initialValue: entry.notes,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => entry.notes = value,
            ),
            if (entry.rawText.isNotEmpty) ...[
              const SizedBox(height: 10),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('View AI transcription'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(entry.rawText),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildImportSummary(ThemeData theme) {
    final validationError = _validateEntries();
    final estimated = _calculateBalanceSummary();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fact_check_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pre-import checks',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (estimated != null) ...[
              Text(
                'Implied starting balance: ${CurrencyFormatter.rupees(estimated.$1)}',
              ),
              Text(
                'Calculated ending balance: ${CurrencyFormatter.rupees(estimated.$2)}',
              ),
              const SizedBox(height: 6),
            ],
            if (validationError == null)
              const Text(
                'Dates, transaction types, amounts, and supplied running balances pass the local checks. The server will validate them again.',
              )
            else
              Text(
                validationError,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            const SizedBox(height: 10),
            const Text(
              'Nothing is saved until you press “Validate & Import Reviewed Entries” and then confirm. Customers with existing ledger transactions are blocked by the server to protect their current balance.',
            ),
          ],
        ),
      ),
    );
  }

  (double, double)? _calculateBalanceSummary() {
    if (_entries.isEmpty) return null;
    final first = _entries.first;
    final firstAmount = double.tryParse(first.amount.trim());
    final firstAfter = double.tryParse(first.writtenBalanceAfter.trim());
    if (firstAmount == null || firstAfter == null) return null;

    final firstEffect = first.type == 'sale' ? firstAmount : -firstAmount;
    final start = firstAfter - firstEffect;
    var running = start;

    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      final amount = double.tryParse(entry.amount.trim());
      if (amount == null) return null;
      running += entry.type == 'sale' ? amount : -amount;
      if (running < -0.01) return null;
      final written = double.tryParse(entry.writtenBalanceAfter.trim());
      if (written != null && (written - running).abs() > 0.01) {
        // Still return the calculated summary; validation text explains mismatch.
      }
    }
    return (start, running);
  }
}

const Set<String> _allowedTypes = {'sale', 'payment', 'return', 'unknown'};
const Set<String> _allowedImportTypes = {'sale', 'payment', 'return'};
const Set<String> _allowedMethods = {
  'cash',
  'cheque',
  'neft',
  'gpay',
  'unknown',
};

class _EditableCardEntry {
  _EditableCardEntry({
    required this.date,
    required this.type,
    required this.amount,
    required this.writtenBalanceAfter,
    required this.paymentMethod,
    required this.notes,
    required this.rawText,
    required this.needsReview,
    required this.reviewReason,
  });

  String date;
  String type;
  String amount;
  String writtenBalanceAfter;
  String paymentMethod;
  String notes;
  String rawText;
  bool needsReview;
  String reviewReason;

  factory _EditableCardEntry.fromJson(Map<String, dynamic> json) {
    String asText(dynamic value) => value == null ? '' : value.toString();

    final rawAmount = json['amount'];
    final rawBalance = json['writtenBalanceAfter'];

    return _EditableCardEntry(
      date: asText(json['date']),
      type: asText(json['type']).isEmpty ? 'unknown' : asText(json['type']),
      amount: rawAmount == null ? '' : asText(rawAmount),
      writtenBalanceAfter: rawBalance == null ? '' : asText(rawBalance),
      paymentMethod: asText(json['paymentMethod']).isEmpty
          ? 'unknown'
          : asText(json['paymentMethod']),
      notes: asText(json['notes']),
      rawText: asText(json['rawText']),
      needsReview: json['needsReview'] == true,
      reviewReason: asText(json['reviewReason']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'date': date,
    'type': type,
    'amount': amount,
    'writtenBalanceAfter': writtenBalanceAfter,
    'paymentMethod': paymentMethod,
    'notes': notes,
    'rawText': rawText,
    'needsReview': needsReview,
    'reviewReason': reviewReason,
  };
}
