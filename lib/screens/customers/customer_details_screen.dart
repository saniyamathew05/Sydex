// Legacy selection helper is retained for backwards-compatible customer flows.
// ignore_for_file: unused_element
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/customer.dart';

import '../../services/customer_service.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:pdf/pdf.dart';

import 'package:pdf/widgets.dart' as pw;

import 'package:printing/printing.dart';
import 'package:file_selector/file_selector.dart';

import '../../services/transaction_service.dart';
import '../../services/payment_receipt_share_service.dart';
import '../../services/payment_method_breakdown.dart';

import '../payments/payment_screen.dart';

import '../purchases/add_purchase_screen.dart';
import '../../services/currency_formatter.dart';
import '../../widgets/edit_payment_dialog.dart';
import '../../theme/sydex_theme.dart';
import '../../widgets/sydex_ui.dart';

class CustomerDetailsScreen extends StatefulWidget {
  final Customer customer;

  const CustomerDetailsScreen({super.key, required this.customer});

  @override
  State<CustomerDetailsScreen> createState() => _CustomerDetailsScreenState();
}

class _CustomerDetailsScreenState extends State<CustomerDetailsScreen> {
  double currentBalance = 0;

  bool isLoading = true;

  List<Map<String, dynamic>> ledgerEntries = [];

  bool _isRefreshingFromDataChange = false;

  bool _isOwner = false;
  bool _sharingReceipt = false;
  final Set<String> _hiddenHistoryIds = <String>{};
  final Set<String> _selectedHistoryIds = <String>{};
  bool _selectingHistory = false;

  final String _selectedHistorySection = 'purchases';
  String _activeTab = 'ledger';
  String _selectedLedgerFilter = 'All';

  @override
  void initState() {
    super.initState();

    TransactionService.dataVersion.addListener(_handleTransactionDataChanged);

    _loadRole();
    _loadHiddenHistory();

    _isRefreshingFromDataChange = true;

    _loadCustomerData().whenComplete(() {
      _isRefreshingFromDataChange = false;
    });
  }

  Future<void> _loadHiddenHistory() async {
    final rows = await Supabase.instance.client
        .from('payments')
        .select('id')
        .eq('customer_id', widget.customer.id)
        .eq('hidden_from_ledger', true);
    if (mounted) {
      setState(() {
      _hiddenHistoryIds
        ..clear()
        ..addAll((rows as List).map((row) => row['id'].toString()));
    });
    }
  }

  Future<void> _hideHistoryEntry(Map<String, dynamic> entry) async {
    final id = entry['id']?.toString();
    if (id == null || id.isEmpty) return;
    if (entry['entry_type']?.toString() != 'payment') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only payments can be hidden. Use Delete to remove this entry.'),
        ),
      );
      return;
    }
    try {
      await Supabase.instance.client.rpc('set_payment_hidden_from_ledger', params: {
        'p_payment_id': id,
        'p_hidden': true,
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not hide entry: $error')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _hiddenHistoryIds.add(id));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Hidden from customer history'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              if (!mounted) return;
              await Supabase.instance.client.rpc('set_payment_hidden_from_ledger', params: {
                'p_payment_id': id,
                'p_hidden': false,
              });
              if (mounted) setState(() => _hiddenHistoryIds.remove(id));
            },
          ),
        ),
      );
  }

  Future<void> _restoreHiddenHistory() async {
    if (_hiddenHistoryIds.isEmpty) return;
    for (final id in _hiddenHistoryIds) {
      await Supabase.instance.client.rpc('set_payment_hidden_from_ledger', params: {
        'p_payment_id': id,
        'p_hidden': false,
      });
    }
    setState(() => _hiddenHistoryIds.clear());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Hidden customer history restored')),
    );
  }

  Future<void> _selectAndHideEntries(List<Map<String, dynamic>> entries) async {
    final selected = <String>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Hide entries from customer history'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: ListView(
              children: entries.map((entry) {
                final id = entry['id']?.toString() ?? '';
                final type = entry['entry_type']?.toString() ?? 'entry';
                return CheckboxListTile(
                  value: selected.contains(id),
                  title: Text(
                    type == 'purchase'
                        ? 'New Sale'
                        : type == 'refusal'
                        ? 'Payment refused'
                        : 'Payment',
                  ),
                  subtitle: Text(_formatDate(entry['transaction_date'])),
                  onChanged: id.isEmpty
                      ? null
                      : (value) => setDialogState(() {
                          if (value == true) {
                            selected.add(id);
                          } else {
                            selected.remove(id);
                          }
                        }),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('Hide selected'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || selected.isEmpty || !mounted) return;
    for (final id in selected) {
      final entry = entries.firstWhere((row) => row['id']?.toString() == id,
          orElse: () => const <String, dynamic>{});
      if (entry['entry_type']?.toString() == 'payment') {
        await Supabase.instance.client.rpc('set_payment_hidden_from_ledger', params: {
          'p_payment_id': id,
          'p_hidden': true,
        });
      }
    }
    await _loadHiddenHistory();
  }

  Future<void> _finishHistorySelection() async {
    if (_selectedHistoryIds.isNotEmpty) {
      final paymentIds = ledgerEntries
          .where((entry) => entry['entry_type']?.toString() == 'payment')
          .map((entry) => entry['id']?.toString())
          .whereType<String>()
          .toSet();
      var skipped = 0;
      for (final id in _selectedHistoryIds) {
        if (!paymentIds.contains(id)) {
          skipped++;
          continue;
        }
        try {
          await Supabase.instance.client.rpc('set_payment_hidden_from_ledger', params: {
            'p_payment_id': id,
            'p_hidden': true,
          });
        } catch (_) {
          skipped++;
        }
      }
      if (skipped > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$skipped selected entr${skipped == 1 ? 'y was' : 'ies were'} not hidden. Only payments can be hidden.',
            ),
          ),
        );
      }
      await _loadHiddenHistory();
      if (mounted) {
        setState(() {
        _selectedHistoryIds.clear();
        _selectingHistory = false;
      });
      }
    } else {
      setState(() => _selectingHistory = false);
    }
  }

  @override
  void dispose() {
    TransactionService.dataVersion.removeListener(
      _handleTransactionDataChanged,
    );

    super.dispose();
  }

  void _handleTransactionDataChanged() {
    if (_isRefreshingFromDataChange || !mounted) {
      return;
    }

    _isRefreshingFromDataChange = true;

    Future<void>.microtask(() async {
      try {
        await _loadCustomerData();
      } finally {
        _isRefreshingFromDataChange = false;
      }
    });
  }

  Future<void> _loadRole() async {
    try {
      final supabase = Supabase.instance.client;

      final role = await supabase.rpc('get_my_role');

      if (!mounted) return;

      setState(() {
        _isOwner = role?.toString() == 'owner';
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _isOwner = false;
      });
    }
  }

  Customer get _displayCustomer =>
      CustomerService.getCustomerById(widget.customer.id) ?? widget.customer;

  // ------------------------------------------------------------

  // LOAD CUSTOMER DATA

  // ------------------------------------------------------------

  Future<void> _loadCustomerData() async {
    setState(() {
      isLoading = true;
    });

    try {
      await TransactionService.loadCustomerBalances();

      final balance = await TransactionService.getCurrentBalanceFromLedger(
        customerId: widget.customer.id,

        openingBalance: _displayCustomer.openingBalance,
      );

      final ledger = await TransactionService.getCustomerLedger(
        widget.customer.id,
        openingBalance: _displayCustomer.openingBalance,
      );
      // A refusal is a visit-history event, not a ledger transaction. Keep
      // loading the normal ledger even if an older database has not yet
      // applied the daily-status visibility policy.
      var refusalEntries = <Map<String, dynamic>>[];
      try {
        final refusals = await Supabase.instance.client
            .from('salesman_customer_daily_status')
            .select('id, status_date, note, created_at, entered_by')
            .eq('customer_id', widget.customer.id)
            .eq('status', 'rejected')
            .order('status_date', ascending: false);
        refusalEntries = (refusals as List)
            .map<Map<String, dynamic>>(
              (row) => {
                'id': 'refusal-${row['id']}',
                'entry_type': 'refusal',
                // Prefer the recorded local calendar date so the refusal
                // remains correct when the customer is opened on a later day.
                'transaction_date':
                    row['created_at']?.toString() ??
                    '${row['status_date']}T00:00:00',
                'status_date': row['status_date'],
                'notes': row['note']?.toString() ?? 'Customer refused payment',
                'amount': 0,
                'amount_received': 0,
              },
            )
            .toList();
      } catch (error) {
        debugPrint('Could not load customer refusal history: $error');
      }

      if (!mounted) return;

      setState(() {
        currentBalance = balance;

        ledgerEntries = [...ledger, ...refusalEntries];

        isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load customer history: $error')),
      );
    }
  }

  Future<void> _refreshCustomerData() async {
    if (_isRefreshingFromDataChange) {
      return;
    }

    _isRefreshingFromDataChange = true;

    try {
      await _loadCustomerData();
    } finally {
      _isRefreshingFromDataChange = false;
    }
  }

  Future<void> _editCustomer() async {
    final businessNameController = TextEditingController(
      text: _displayCustomer.businessName,
    );

    final locationController = TextEditingController(
      text: _displayCustomer.location,
    );

    final phoneController = TextEditingController(text: _displayCustomer.phone);

    final openingBalanceController = TextEditingController(
      text: _displayCustomer.openingBalance.toStringAsFixed(2),
    );

    final formKey = GlobalKey<FormState>();

    bool isSaving = false;

    final saved = await showDialog<bool>(
      context: context,

      barrierDismissible: !isSaving,

      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              if (!formKey.currentState!.validate()) return;

              setDialogState(() {
                isSaving = true;
              });

              final success = await CustomerService.updateCustomer(
                customerId: widget.customer.id,

                businessName: businessNameController.text,

                location: locationController.text,

                phone: phoneController.text,

                openingBalance:
                    double.tryParse(
                      openingBalanceController.text.trim().replaceAll(',', ''),
                    ) ??
                    0,
              );

              if (!mounted || !dialogContext.mounted) return;

              if (success) {
                Navigator.pop(dialogContext, true);
              } else {
                setDialogState(() {
                  isSaving = false;
                });

                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      CustomerService.errorMessage ??
                          'Could not update customer.',
                    ),
                  ),
                );
              }
            }

            return AlertDialog(
              title: const Text('Edit Customer'),

              content: Form(
                key: formKey,

                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,

                    children: [
                      TextFormField(
                        controller: businessNameController,

                        textInputAction: TextInputAction.next,

                        decoration: const InputDecoration(
                          labelText: 'Business name',

                          prefixIcon: Icon(Icons.business_outlined),
                        ),

                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Business name is required.';
                          }

                          return null;
                        },
                      ),

                      const SizedBox(height: 14),

                      TextFormField(
                        controller: locationController,

                        textInputAction: TextInputAction.next,

                        decoration: const InputDecoration(
                          labelText: 'Location',

                          prefixIcon: Icon(Icons.location_on_outlined),
                        ),

                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Location is required.';
                          }

                          return null;
                        },
                      ),

                      const SizedBox(height: 14),

                      TextFormField(
                        controller: phoneController,

                        keyboardType: TextInputType.phone,

                        textInputAction: TextInputAction.done,

                        decoration: const InputDecoration(
                          labelText: 'Phone number',

                          prefixIcon: Icon(Icons.phone_outlined),
                        ),

                        validator: (value) {
                          return null;
                        },
                      ),

                      const SizedBox(height: 14),

                      TextFormField(
                        controller: openingBalanceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Opening balance',
                          prefixText: '₹ ',
                          prefixIcon: Icon(
                            Icons.account_balance_wallet_outlined,
                          ),
                        ),
                        validator: (value) {
                          final amount = double.tryParse(
                            (value ?? '').trim().replaceAll(',', ''),
                          );
                          if (amount == null) {
                            return 'Enter a valid opening balance.';
                          }
                          if (amount < 0) {
                            return 'Opening balance cannot be negative.';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),

              actions: [
                TextButton(
                  onPressed: isSaving
                      ? null
                      : () => Navigator.pop(dialogContext, false),

                  child: const Text('Cancel'),
                ),

                FilledButton(
                  onPressed: isSaving ? null : save,

                  child: isSaving
                      ? const SizedBox(
                          width: 20,

                          height: 20,

                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );

    businessNameController.dispose();

    locationController.dispose();

    phoneController.dispose();

    openingBalanceController.dispose();

    if (saved == true && mounted) {
      final updatedCustomer = CustomerService.getCustomerById(
        widget.customer.id,
      );

      if (updatedCustomer != null) {
        setState(() {});
      }

      await _refreshCustomerData();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer updated successfully.')),
      );
    }
  }

  // ------------------------------------------------------------

  // NEW PURCHASE

  // ------------------------------------------------------------

  // ------------------------------------------------------------

  // CALL CUSTOMER

  // ------------------------------------------------------------

  Future<void> _callCustomer() async {
    final phone = _displayCustomer.phone.trim();

    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This customer does not have a phone number.'),
        ),
      );

      return;
    }

    final uri = Uri(scheme: 'tel', path: phone);

    try {
      final launched = await launchUrl(uri);

      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the phone dialer.')),
        );
      }
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not call customer: $error')),
      );
    }
  }

  Future<void> _whatsappCustomer() async {
    try {
      await PaymentReceiptShareService.openCustomerChat(_displayCustomer);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open WhatsApp: $error')),
      );
    }
  }

  Future<void> _shareCustomerReceipt() async {
    if (_sharingReceipt) return;
    setState(() => _sharingReceipt = true);
    try {
      await PaymentReceiptShareService.shareLatest(
        context: context,
        customer: _displayCustomer,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share receipt: $error')),
      );
    } finally {
      if (mounted) setState(() => _sharingReceipt = false);
    }
  }

  // ------------------------------------------------------------

  // CUSTOMER STATEMENT PDF

  // ------------------------------------------------------------

  Future<void> _exportCustomerStatement() async {
    Uint8List? generatedPdfBytes;

    if (ledgerEntries.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('There are no transactions to export yet.'),
        ),
      );
      return;
    }

    try {
      final customer = _displayCustomer;
      final pdf = pw.Document();

      double totalPurchases = 0;
      double totalSettled = 0;
      double totalDiscount = 0;
      double totalReceived = 0;
      double totalReturns = 0;

      final exportEntries = List<Map<String, dynamic>>.from(ledgerEntries);
      exportEntries.sort((a, b) {
        final dateA = DateTime.tryParse(
          a['transaction_date']?.toString() ?? '',
        );
        final dateB = DateTime.tryParse(
          b['transaction_date']?.toString() ?? '',
        );

        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });

      for (final entry in exportEntries) {
        final type = entry['entry_type']?.toString() ?? '';
        final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
        final discount = (entry['discount'] as num?)?.toDouble() ?? 0;
        final amountReceived = entry['is_bounced'] == true
            ? 0.0
            : (entry['amount_received'] as num?)?.toDouble() ??
                  (amount - discount);

        if (type == 'purchase') {
          totalPurchases += amount;
          totalDiscount += discount;
        } else if (type == 'payment' && entry['is_bounced'] != true) {
          totalSettled += amount;
          totalDiscount += discount;
          totalReceived += amountReceived;
        } else if (type == 'return') {
          totalReturns += amount;
        }
      }

      final generatedAt = _formatDate(DateTime.now().toIso8601String());

      pdf.addPage(
        pw.MultiPage(
          pageTheme: pw.PageTheme(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(28),
          ),
          build: (context) {
            return [
              pw.Text(
                'CUSTOMER STATEMENT',
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                customer.businessName,
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text('Location: ${customer.location}'),
              pw.Text('Phone: ${customer.phone}'),
              pw.Text('Generated: $generatedAt'),
              pw.SizedBox(height: 18),
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(6),
                  ),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    _pdfSummaryItem('Sales', _money(totalPurchases)),
                    _pdfSummaryItem('Returns', _money(totalReturns)),
                    _pdfSummaryItem('Settled', _money(totalSettled)),
                    _pdfSummaryItem('Discount', _money(totalDiscount)),
                    _pdfSummaryItem('Received', _money(totalReceived)),
                    _pdfSummaryItem(
                      currentBalance < 0 ? 'Advance' : 'Balance Due',
                      _money(currentBalance.abs()),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Text(
                'Transaction History',
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 8,
                ),
                cellStyle: const pw.TextStyle(fontSize: 7),
                cellPadding: const pw.EdgeInsets.all(5),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.grey200,
                ),
                headers: const [
                  'Date',
                  'Type',
                  'Amount',
                  'Discount',
                  'Received',
                  'Balance',
                  'Received By',
                ],
                data: exportEntries.map((entry) {
                  final type = entry['entry_type']?.toString() ?? '';
                  final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
                  final discount = (entry['discount'] as num?)?.toDouble() ?? 0;
                  final received = entry['is_bounced'] == true
                      ? 0.0
                      : (entry['amount_received'] as num?)?.toDouble() ??
                            (amount - discount);
                  final balanceAfter =
                      (entry['balance_after'] as num?)?.toDouble() ?? 0;
                  final profile = entry['profiles'];
                  final receivedBy = profile is Map
                      ? profile['name']?.toString() ?? 'User'
                      : 'User';

                  return [
                    _formatDate(entry['transaction_date']),
                    type == 'purchase'
                        ? 'Purchase'
                        : type == 'return'
                        ? 'Sales Return'
                        : 'Payment',
                    _money(amount),
                    (type == 'payment' || type == 'purchase')
                        ? _money(discount)
                        : 'Rs. 0.00',
                    type == 'payment' ? _money(received) : 'Rs. 0.00',
                    CurrencyFormatter.balanceAfter(balanceAfter),
                    receivedBy,
                  ];
                }).toList(),
              ),
              pw.SizedBox(height: 18),
              pw.Text(
                '${currentBalance < 0 ? 'Customer Advance' : 'Current Amount Due'}: ${_money(currentBalance.abs())}',
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                'This statement is generated from the business payment ledger.',
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey700,
                ),
              ),
            ];
          },
        ),
      );

      final bytes = await pdf.save();
      generatedPdfBytes = bytes;

      if (bytes.isEmpty) {
        throw Exception('PDF generation returned an empty file.');
      }

      final safeName = customer.businessName
          .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      final fileName =
          '${safeName.isEmpty ? 'customer' : safeName}_statement.pdf';

      // macOS sandbox does not allow the app to write directly to ~/Downloads.
      // Ask the user for a destination through the native Save dialog instead.
      final saveLocation = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PDF Document', extensions: ['pdf']),
        ],
      );

      if (saveLocation == null) {
        return;
      }

      final outputFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'application/pdf',
      );
      await outputFile.saveTo(saveLocation.path);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Customer statement saved successfully:\n${saveLocation.path}',
          ),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () async {
              try {
                await Process.run('open', [saveLocation.path]);
              } catch (openError) {
                debugPrint('CUSTOMER STATEMENT OPEN ERROR: $openError');
              }
            },
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('CUSTOMER STATEMENT EXPORT ERROR: $error');
      debugPrint('CUSTOMER STATEMENT EXPORT STACK: $stackTrace');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not export customer statement: $error'),
          duration: const Duration(seconds: 8),
          action: generatedPdfBytes != null && generatedPdfBytes.isNotEmpty
              ? SnackBarAction(
                  label: 'Share',
                  onPressed: () async {
                    try {
                      await Printing.sharePdf(
                        bytes: generatedPdfBytes!,
                        filename: 'customer_statement.pdf',
                      );
                    } catch (shareError) {
                      debugPrint('CUSTOMER STATEMENT SHARE ERROR: $shareError');
                    }
                  },
                )
              : null,
        ),
      );
    }
  }

  pw.Widget _pdfSummaryItem(String title, String value) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,

      children: [
        pw.Text(
          title,

          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),

        pw.SizedBox(height: 3),

        pw.Text(
          value,

          style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        ),
      ],
    );
  }

  Future<void> _newPurchase() async {
    await Navigator.push(
      context,

      MaterialPageRoute(
        builder: (_) => AddPurchaseScreen(initialCustomer: _displayCustomer),
      ),
    );

    await _refreshCustomerData();
  }

  // ------------------------------------------------------------

  // RECORD PAYMENT

  // ------------------------------------------------------------

  Future<void> _recordPayment() async {
    await Navigator.push(
      context,

      MaterialPageRoute(
        builder: (_) => PaymentScreen(
          customer: _displayCustomer,
          offerLocation: _isOwner,
        ),
      ),
    );

    await _refreshCustomerData();
  }

  Future<void> _editReceivedPayment(
    Map<String, dynamic> entry, {
    bool dateOnly = false,
  }) async {
    final paymentId = entry['id']?.toString();
    if (paymentId == null || paymentId.isEmpty) return;
    final result = await showEditPaymentDialog(
      context,
      amount: (entry['amount'] as num?)?.toDouble() ?? 0,
      discount: (entry['discount'] as num?)?.toDouble() ?? 0,
      notes: entry['notes']?.toString() ?? '',
      method: entry['payment_method']?.toString() ?? 'cash',
      methodNote: entry['payment_method_note']?.toString() ?? '',
      transactionDate:
          DateTime.tryParse(entry['transaction_date']?.toString() ?? '') ??
          DateTime.now(),
      dateOnly: dateOnly,
    );
    if (result == null || !mounted) return;

    final success = await TransactionService.updatePayment(
      paymentId: paymentId,
      amount: result.amount,
      discount: result.discount,
      notes: result.notes,
      paymentMethod: result.method,
      paymentMethodNote: result.methodNote,
      transactionDate: result.transactionDate,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Payment updated.'
              : (TransactionService.errorMessage ??
                    'Could not update payment.'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (success) await _refreshCustomerData();
  }

  // ------------------------------------------------------------

  // EDIT PURCHASE

  // ------------------------------------------------------------

  Future<void> _editPurchase(Map<String, dynamic> entry) async {
    final entryId = entry['id']?.toString();

    if (entryId == null || entryId.isEmpty) {
      return;
    }

    final originalAmount = (entry['amount'] as num?)?.toDouble() ?? 0;

    final originalNotes = entry['notes']?.toString() ?? '';

    DateTime originalDate;

    try {
      originalDate = DateTime.parse(
        entry['transaction_date'].toString(),
      ).toLocal();
    } catch (_) {
      originalDate = DateTime.now();
    }

    final amountController = TextEditingController(
      text: originalAmount.toStringAsFixed(2),
    );

    final notesController = TextEditingController(text: originalNotes);

    DateTime selectedDate = originalDate;

    bool isSaving = false;

    final result = await showDialog<bool>(
      context: context,

      barrierDismissible: !isSaving,

      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              final amount = double.tryParse(amountController.text.trim());

              if (amount == null || !amount.isFinite || amount <= 0) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Enter a valid purchase amount.'),
                  ),
                );

                return;
              }

              setDialogState(() {
                isSaving = true;
              });

              final transactionDate = DateTime(
                selectedDate.year,

                selectedDate.month,

                selectedDate.day,

                originalDate.hour,

                originalDate.minute,

                originalDate.second,
              );

              try {
                await Supabase.instance.client.rpc(
                  'update_purchase',

                  params: {
                    'p_entry_id': entryId,

                    'p_amount': amount,

                    'p_notes': notesController.text.trim().isEmpty
                        ? null
                        : notesController.text.trim(),

                    'p_transaction_date': transactionDate
                        .toUtc()
                        .toIso8601String(),
                  },
                );

                if (!dialogContext.mounted) return;

                Navigator.of(dialogContext).pop(true);
              } catch (error) {
                if (!dialogContext.mounted) return;

                setDialogState(() {
                  isSaving = false;
                });

                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text('Could not update purchase: $error')),
                );
              }
            }

            return AlertDialog(
              title: const Text('Edit Sale'),

              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,

                  children: [
                    TextField(
                      controller: amountController,

                      enabled: !isSaving,

                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),

                      decoration: const InputDecoration(
                        labelText: 'Sale Amount',

                        prefixText: 'Rs. ',
                      ),
                    ),

                    const SizedBox(height: 16),

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

                              if (picked == null) return;

                              setDialogState(() {
                                selectedDate = picked;
                              });
                            },

                      borderRadius: BorderRadius.circular(12),

                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Sale Date',

                          prefixIcon: Icon(Icons.calendar_today_outlined),
                        ),

                        child: Text(_formatDate(selectedDate)),
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: notesController,

                      enabled: !isSaving,

                      maxLines: 3,

                      textCapitalization: TextCapitalization.sentences,

                      decoration: const InputDecoration(
                        labelText: 'New Order / Note',

                        hintText: 'Optional new order or note',

                        alignLabelWithHint: true,
                      ),
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
                  onPressed: isSaving ? null : save,

                  child: isSaving
                      ? const SizedBox(
                          width: 20,

                          height: 20,

                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );

    amountController.dispose();

    notesController.dispose();

    if (result != true || !mounted) {
      return;
    }

    await _refreshAfterPurchaseChange();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Purchase updated successfully.')),
    );
  }

  // ------------------------------------------------------------

  // DELETE PURCHASE

  // ------------------------------------------------------------

  bool _isPurchaseFullyPaid(Map<String, dynamic> purchase) {
    if (purchase['entry_type']?.toString() != 'purchase') {
      return false;
    }

    final purchaseId = purchase['id']?.toString();
    final balanceBefore = (purchase['balance_before'] as num?)?.toDouble() ?? 0;

    if (purchaseId == null || purchaseId.isEmpty) {
      return false;
    }

    final chronologicalEntries = List<Map<String, dynamic>>.from(ledgerEntries)
      ..sort((a, b) {
        final dateA = DateTime.tryParse(
          a['transaction_date']?.toString() ?? '',
        );
        final dateB = DateTime.tryParse(
          b['transaction_date']?.toString() ?? '',
        );

        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });

    final purchaseIndex = chronologicalEntries.indexWhere(
      (entry) => entry['id']?.toString() == purchaseId,
    );

    if (purchaseIndex < 0) {
      return false;
    }

    for (
      var index = purchaseIndex + 1;
      index < chronologicalEntries.length;
      index++
    ) {
      final laterEntry = chronologicalEntries[index];

      if (laterEntry['entry_type']?.toString() != 'payment') {
        continue;
      }

      final paymentBalanceAfter = (laterEntry['balance_after'] as num?)
          ?.toDouble();

      if (paymentBalanceAfter != null &&
          paymentBalanceAfter <= balanceBefore + 0.01) {
        return true;
      }
    }

    return false;
  }

  bool _isAccidentalPurchase(Map<String, dynamic> purchase) {
    if (purchase['entry_type']?.toString() != 'purchase') {
      return false;
    }

    if (_isPurchaseFullyPaid(purchase)) {
      return false;
    }

    final purchaseId = purchase['id']?.toString();
    if (purchaseId == null || purchaseId.isEmpty) {
      return false;
    }

    final chronologicalEntries = List<Map<String, dynamic>>.from(ledgerEntries)
      ..sort((a, b) {
        final dateA = DateTime.tryParse(
          a['transaction_date']?.toString() ?? '',
        );
        final dateB = DateTime.tryParse(
          b['transaction_date']?.toString() ?? '',
        );

        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });

    final purchaseIndex = chronologicalEntries.indexWhere(
      (entry) => entry['id']?.toString() == purchaseId,
    );

    if (purchaseIndex < 0) {
      return false;
    }

    // An accidental purchase is one that has not been paid at all.
    // Once any payment has been recorded after it, keep it protected
    // until the purchase is fully settled.
    for (
      var index = purchaseIndex + 1;
      index < chronologicalEntries.length;
      index++
    ) {
      if (chronologicalEntries[index]['entry_type']?.toString() == 'payment') {
        return false;
      }
    }

    return true;
  }

  Future<void> _deletePurchase(Map<String, dynamic> entry) async {
    final entryId = entry['id']?.toString();

    if (entryId == null || entryId.isEmpty) {
      return;
    }

    final isPaid = _isPurchaseFullyPaid(entry);
    final isAccidental = _isAccidentalPurchase(entry);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete Sale?'),
          content: Text(
            isPaid
                ? 'This sale has already been fully paid. It will be removed and the customer balance recalculated. Payment records stay unchanged.'
                : isAccidental
                ? 'This sale has no payment recorded after it. Delete it permanently and recalculate the customer balance?'
                : 'Payments were recorded after this sale. Deleting it will recalculate the balance, which may turn into an advance (credit) for the customer. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(isPaid ? 'Remove' : 'Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    try {
      await Supabase.instance.client.rpc(
        'delete_purchase',

        params: {'p_entry_id': entryId},
      );

      await _refreshAfterPurchaseChange();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Purchase deleted successfully.')),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete purchase: $error')),
      );
    }
  }

  String _paymentMethodLabel(String method) {
    switch (method) {
      case 'cheque':
        return 'Cheque / Check';
      case 'neft':
        return 'Online - NEFT';
      case 'gpay':
        return 'Online - GPay';
      case 'cash':
      default:
        return 'Cash';
    }
  }

  Future<void> _markChequeBounced(Map<String, dynamic> entry) async {
    final paymentId = entry['id']?.toString();
    if (paymentId == null || paymentId.isEmpty) return;

    final bankChargeController = TextEditingController(text: '0');
    final notesController = TextEditingController();
    bool isSaving = false;
    bool addBankChargeToBalance = true;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: !isSaving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              final bankCharge =
                  double.tryParse(
                    bankChargeController.text.trim().replaceAll(',', ''),
                  ) ??
                  -1;

              if (bankCharge < 0) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Enter a valid bank charge.')),
                );
                return;
              }

              setDialogState(() => isSaving = true);

              try {
                await Supabase.instance.client.rpc(
                  'record_bounced_cheque',
                  params: {
                    'p_payment_id': paymentId,
                    'p_bank_charge': bankCharge,
                    'p_notes': notesController.text.trim().isEmpty
                        ? null
                        : notesController.text.trim(),
                    'p_transaction_date': DateTime.now()
                        .toUtc()
                        .toIso8601String(),
                    'p_add_bank_charge': addBankChargeToBalance,
                  },
                );

                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop(true);
              } catch (error) {
                if (!dialogContext.mounted) return;
                setDialogState(() => isSaving = false);
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text('Could not mark cheque as bounced: $error'),
                  ),
                );
              }
            }

            return AlertDialog(
              title: const Text('Cheque Bounced'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _detailRow(
                      'Cheque Amount',
                      _money((entry['amount'] as num?)?.toDouble() ?? 0),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: bankChargeController,
                      enabled: !isSaving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Bank Charges',
                        prefixText: '₹ ',
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: addBankChargeToBalance,
                      onChanged: isSaving
                          ? null
                          : (value) {
                              setDialogState(() {
                                addBankChargeToBalance = value ?? false;
                              });
                            },
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Add bank charges to customer balance'),
                      subtitle: const Text(
                        'Untick to record the bounced cheque without adding bank charges to the amount due.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: notesController,
                      enabled: !isSaving,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Note',
                        hintText: 'Optional bounce reason / bank reference',
                      ),
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
                  onPressed: isSaving ? null : save,
                  child: isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Mark Bounced'),
                ),
              ],
            );
          },
        );
      },
    );

    bankChargeController.dispose();
    notesController.dispose();

    if (confirmed == true && mounted) {
      await _refreshCustomerData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            addBankChargeToBalance
                ? 'Cheque bounced. Bank charges were added to the customer balance.'
                : 'Cheque bounced. Bank charges were recorded but not added to the customer balance.',
          ),
        ),
      );
    }
  }

  Future<void> _recordReturn() async {
    final amountController = TextEditingController();

    final notesController = TextEditingController();

    DateTime selectedDate = DateTime.now();

    bool isSaving = false;

    final result = await showDialog<bool>(
      context: context,

      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              final amount = double.tryParse(
                amountController.text.trim().replaceAll(',', ''),
              );

              if (amount == null || !amount.isFinite || amount <= 0) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Enter a valid return amount.')),
                );

                return;
              }

              setDialogState(() {
                isSaving = true;
              });

              try {
                await Supabase.instance.client.rpc(
                  'record_return',

                  params: {
                    'p_customer_id': widget.customer.id,

                    'p_amount': amount,

                    'p_notes': notesController.text.trim().isEmpty
                        ? null
                        : notesController.text.trim(),

                    'p_transaction_date': DateTime(
                      selectedDate.year,

                      selectedDate.month,

                      selectedDate.day,
                    ).toUtc().toIso8601String(),
                  },
                );

                if (!dialogContext.mounted) return;

                Navigator.of(dialogContext).pop(true);
              } catch (error) {
                if (!dialogContext.mounted) return;

                setDialogState(() {
                  isSaving = false;
                });

                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text('Could not record return: $error')),
                );
              }
            }

            return AlertDialog(
              title: const Text('Return Products'),

              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,

                  children: [
                    _detailRow(
                      currentBalance < 0 ? 'Advance' : 'Current Amount Due',
                      _money(currentBalance.abs()),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: amountController,

                      enabled: !isSaving,

                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),

                      decoration: const InputDecoration(
                        labelText: 'Return Amount',
                        helperText:
                            'Excess return becomes credit owed to the customer.',
                        helperMaxLines: 2,

                        hintText: 'e.g. 500',

                        prefixText: 'Rs. ',
                      ),
                    ),

                    const SizedBox(height: 16),

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

                              if (picked == null) return;

                              setDialogState(() {
                                selectedDate = picked;
                              });
                            },

                      borderRadius: BorderRadius.circular(12),

                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Return Date',

                          prefixIcon: Icon(Icons.calendar_today_outlined),
                        ),

                        child: Text(_formatDate(selectedDate)),
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: notesController,

                      enabled: !isSaving,

                      maxLines: 3,

                      textCapitalization: TextCapitalization.sentences,

                      decoration: const InputDecoration(
                        labelText: 'Reason / Note',

                        hintText: 'Optional reason or note about the return',

                        alignLabelWithHint: true,
                      ),
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
                  onPressed: isSaving ? null : save,

                  child: isSaving
                      ? const SizedBox(
                          width: 20,

                          height: 20,

                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Confirm Return'),
                ),
              ],
            );
          },
        );
      },
    );

    amountController.dispose();

    notesController.dispose();

    if (result != true || !mounted) {
      return;
    }

    await _refreshAfterPurchaseChange();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Return recorded successfully.')),
    );
  }

  Future<void> _editReturn(Map<String, dynamic> entry) async {
    final amount = TextEditingController(text: ((entry['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2));
    final notes = TextEditingController(text: entry['notes']?.toString() ?? '');
    var date = DateTime.tryParse(entry['transaction_date']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    final result = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setState) => AlertDialog(
      title: const Text('Edit sales return'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Return amount')),
        TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes')),
        ListTile(title: const Text('Return date'), subtitle: Text(_formatDate(date)), onTap: () async { final picked = await showDatePicker(context: dialogContext, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (picked != null) setState(() => date = picked); }),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () async {
        final parsed = double.tryParse(amount.text.trim().replaceAll(',', ''));
        if (parsed == null || parsed <= 0) {
          ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('Enter a valid return amount.')));
          return;
        }
        try {
          await Supabase.instance.client.rpc('update_return', params: {'p_entry_id': entry['id'], 'p_amount': parsed, 'p_notes': notes.text.trim(), 'p_transaction_date': date.toUtc().toIso8601String()});
          if (dialogContext.mounted) Navigator.pop(dialogContext, true);
        } catch (error) {
          if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text('Could not update return: $error')));
        }
      }, child: const Text('Save'))],
    )));
    amount.dispose(); notes.dispose();
    if (result == true) await _refreshAfterPurchaseChange();
  }

  Future<void> _changeEntryDate(Map<String, dynamic> entry) async {
    final entryId = entry['id']?.toString();
    if (entryId == null || entryId.isEmpty) return;
    final current =
        DateTime.tryParse(
          entry['transaction_date']?.toString() ?? '',
        )?.toLocal() ??
        DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Change entry date',
    );
    if (picked == null || !mounted) return;
    try {
      await Supabase.instance.client.rpc(
        'update_entry_date',
        params: {
          'p_entry_id': entryId,
          'p_transaction_date': DateTime(
            picked.year,
            picked.month,
            picked.day,
            current.hour,
            current.minute,
            current.second,
          ).toUtc().toIso8601String(),
        },
      );
      await _refreshAfterPurchaseChange();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Date updated.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not change the date: $error')),
        );
      }
    }
  }

  Future<void> _deleteReceivedPayment(Map<String, dynamic> entry) async {
    final paymentId = (entry['related_payment_id'] ?? entry['id'])?.toString();
    if (paymentId == null || paymentId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete payment?'),
        content: Text(
          'Delete the payment of ${_money((entry['amount'] as num?)?.toDouble() ?? 0)}? The customer balance and all later balances will be recalculated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success = await TransactionService.deletePayment(paymentId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Payment deleted and balance recalculated.'
              : (TransactionService.errorMessage ??
                    'Could not delete the payment.'),
        ),
      ),
    );
    if (success) await _refreshAfterPurchaseChange();
  }

  Future<void> _deleteSalesReturn(Map<String, dynamic> entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete sales return?'),
        content: const Text('This will remove the return and recalculate the customer balance and all later payment balances.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await Supabase.instance.client.rpc('delete_sales_return', params: {'p_entry_id': entry['id']});
      await _refreshAfterPurchaseChange();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sales return deleted and balance recalculated.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete sales return: $error')));
    }
  }

  Future<void> _refreshAfterPurchaseChange() async {
    _isRefreshingFromDataChange = true;

    try {
      await TransactionService.loadCustomerBalances();

      await TransactionService.loadTransactions();

      await _loadCustomerData();
    } finally {
      _isRefreshingFromDataChange = false;
    }
  }

  // ------------------------------------------------------------

  // MONEY FORMAT

  // ------------------------------------------------------------

  String _money(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? 0;

    return CurrencyFormatter.rupees(number);
  }

  // ------------------------------------------------------------

  // DATE FORMAT

  // ------------------------------------------------------------

  String _formatDate(dynamic value) {
    if (value == null) {
      return '';
    }

    try {
      final date = DateTime.parse(value.toString()).toLocal();

      final day = date.day.toString().padLeft(2, '0');

      final month = date.month.toString().padLeft(2, '0');

      final year = date.year.toString();

      final hour = date.hour == 0
          ? 12
          : date.hour > 12
          ? date.hour - 12
          : date.hour;

      final minute = date.minute.toString().padLeft(2, '0');

      final period = date.hour >= 12 ? 'PM' : 'AM';

      return '$day/$month/$year  '
          '$hour:$minute $period';
    } catch (_) {
      return value.toString();
    }
  }

  // ------------------------------------------------------------

  // DISPLAYED TRANSACTIONS

  // ------------------------------------------------------------

  List<Map<String, dynamic>> get _displayedPurchaseEntries {
    return ledgerEntries
        .where((entry) => entry['entry_type']?.toString() == 'purchase')
        .toList();
  }

  // ------------------------------------------------------------

  // BUILD

  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final customer = _displayCustomer;
    final allEntries =
        ledgerEntries
            .where(
              (entry) => !_hiddenHistoryIds.contains(entry['id']?.toString()),
            )
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList()
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

    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshCustomerData,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      MediaQuery.paddingOf(context).top + 12,
                      20,
                      24,
                    ),
                    children: [
                      Row(
                        children: [
                          SydexIconButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: 'Back',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const Spacer(),
                          if (_isOwner)
                            SydexIconButton(
                              icon: Icons.edit_outlined,
                              tooltip: 'Edit customer',
                              onPressed: _editCustomer,
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      SydexReveal(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (customer.location.trim().isNotEmpty)
                              SydexEyebrow(customer.location),
                            const SizedBox(height: 6),
                            Text(
                              customer.businessName,
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -.8,
                                height: 1.1,
                                color: colors.onSurface,
                              ),
                            ),
                            if (customer.phone.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                customer.phone,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SydexReveal(
                        index: 1,
                        child: SydexHeroCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SydexEyebrow(
                                currentBalance < 0
                                    ? 'Advance (credit)'
                                    : 'Current amount due',
                                color: Colors.white.withValues(alpha: .62),
                              ),
                              const SizedBox(height: 6),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _money(currentBalance.abs()),
                                  style: const TextStyle(
                                    fontSize: 36,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -1,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Opening balance ${_money(customer.openingBalance)}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.white.withValues(alpha: .62),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SydexReveal(
                        index: 2,
                        child: SydexAutoGrid(
                          minItemWidth: 70,
                          itemHeight: 98,
                          minColumns: 4,
                          spacing: 4,
                          runSpacing: 10,
                          children: [
                            SydexQuickAction(
                              icon: Icons.add_rounded,
                              label: 'Add sale',
                              onTap: _newPurchase,
                            ),
                            SydexQuickAction(
                              icon: Icons.account_balance_wallet_outlined,
                              label: 'Add payment',
                              onTap: _recordPayment,
                            ),
                            SydexQuickAction(
                              icon: Icons.assignment_return_outlined,
                              label: 'Return',
                              onTap: _recordReturn,
                            ),
                            SydexQuickAction(
                              icon: Icons.ios_share_rounded,
                              label: _sharingReceipt ? 'Preparing…' : 'Share receipt',
                              onTap: _sharingReceipt ? null : _shareCustomerReceipt,
                            ),
                            SydexQuickAction(
                              icon: Icons.call_outlined,
                              label: 'Call',
                              onTap: _callCustomer,
                            ),
                            SydexQuickAction(
                              icon: Icons.chat_outlined,
                              label: 'WhatsApp',
                              onTap: _whatsappCustomer,
                            ),
                            SydexQuickAction(
                              icon: Icons.picture_as_pdf_outlined,
                              label: 'Statement',
                              onTap: _exportCustomerStatement,
                            ),
                            SydexQuickAction(
                              icon: Icons.visibility_off_outlined,
                              label: 'Hide entries',
                              onTap: _isOwner
                                  ? () => setState(() {
                                      _activeTab = 'ledger';
                                      _selectingHistory = true;
                                    })
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SydexChoiceChips(
                        options: const ['Ledger', 'Details', 'Sales', 'Photos'],
                        selected: switch (_activeTab) {
                          'details' => 'Details',
                          'purchases' => 'Sales',
                          'photos' => 'Photos',
                          _ => 'Ledger',
                        },
                        onSelected: (label) => setState(
                          () => _activeTab = switch (label) {
                            'Details' => 'details',
                            'Sales' => 'purchases',
                            'Photos' => 'photos',
                            _ => 'ledger',
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_activeTab == 'ledger') ...[
                        _buildLedgerFilterSelector(),
                        if (_hiddenHistoryIds.isNotEmpty)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _restoreHiddenHistory,
                              icon: const Icon(Icons.visibility_outlined),
                              label: Text(
                                'Restore hidden entries (${_hiddenHistoryIds.length})',
                              ),
                            ),
                          ),
                        if (_selectingHistory)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _finishHistorySelection,
                              child: Text(
                                'Hide from ledger (${_selectedHistoryIds.length})',
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        if (_filteredLedgerEntries(allEntries).isEmpty)
                          _buildEmptyHistory()
                        else
                          ..._filteredLedgerEntries(
                            allEntries,
                          ).map(_buildLedgerEntry),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _exportCustomerStatement,
                            icon: const Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 17,
                            ),
                            label: const Text('Export customer statement'),
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                            ),
                          ),
                        ),
                      ] else if (_activeTab == 'details') ...[
                        _buildDetailsPanel(),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 44,
                          child: OutlinedButton.icon(
                            onPressed: _exportCustomerStatement,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('Export Customer Statement'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 44,
                          child: OutlinedButton.icon(
                            onPressed: _recordReturn,
                            icon: const Icon(Icons.assignment_return_outlined),
                            label: const Text('Record Sales Return'),
                          ),
                        ),
                      ] else if (_activeTab == 'purchases') ...[
                        _sectionHeading(
                          'Sales History',
                          _displayedPurchaseEntries.length,
                        ),
                        if (_displayedPurchaseEntries.isEmpty)
                          _buildEmptyHistory()
                        else
                          ..._displayedPurchaseEntries.map(_buildLedgerEntry),
                      ] else ...[
                        _sectionHeading('Signatures & Photos', 0),
                        ...ledgerEntries
                            .where(
                              (entry) =>
                                  (entry['signature_path']?.toString() ?? '')
                                      .isNotEmpty,
                            )
                            .map(
                              (entry) => Card(
                                elevation: 0,
                                color: Theme.of(context).colorScheme.surface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry['transaction_date']?.toString() ??
                                            'Transaction',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      _SignaturePreview(
                                        signaturePath: entry['signature_path']
                                            .toString(),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        if (!ledgerEntries.any(
                          (entry) => (entry['signature_path']?.toString() ?? '')
                              .isNotEmpty,
                        ))
                          _emptyPhotosCard(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
      bottomNavigationBar: isLoading
          ? null
          : SafeArea(
              top: false,
              child: Container(
                padding: sydexPageInsets(
                  MediaQuery.sizeOf(context).width,
                  maxWidth: 920,
                  top: 10,
                  bottom: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _newPurchase,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add sale', maxLines: 1),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _recordPayment,
                        icon: const Icon(Icons.south_west_rounded, size: 18),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Receive payment', maxLines: 1),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildDetailsPanel() {
    final customer = _displayCustomer;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Customer Details',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _detailRow('Business name', customer.businessName),
          _detailRow('Location', customer.location),
          _detailRow('Phone number', customer.phone),
          _detailRow('Opening balance', _money(customer.openingBalance)),
          const Divider(height: 22),
          _detailRow(
            currentBalance < 0 ? 'Advance' : 'Current balance',
            _money(currentBalance.abs()),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _callCustomer,
                icon: const Icon(Icons.call_outlined, size: 16),
                label: const Text('Call'),
              ),
              OutlinedButton.icon(
                onPressed: _whatsappCustomer,
                icon: const Icon(Icons.chat_outlined, size: 16),
                label: const Text('WhatsApp'),
              ),
              OutlinedButton.icon(
                onPressed: _sharingReceipt ? null : _shareCustomerReceipt,
                icon: const Icon(Icons.receipt_long_outlined, size: 16),
                label: Text(
                  _sharingReceipt ? 'Preparing receipt…' : 'Share receipt',
                ),
              ),
              if (_isOwner)
                OutlinedButton.icon(
                  onPressed: _editCustomer,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit customer'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeading(String title, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 3, 2, 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _emptyPhotosCard() => Container(
    padding: const EdgeInsets.all(26),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      children: [
        Icon(Icons.photo_library_outlined, size: 38, color: Color(0xFF8A867F)),
        SizedBox(height: 8),
        Text(
          'No signatures or photos yet',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------

  // CUSTOMER HEADER

  // ------------------------------------------------------------

  // ------------------------------------------------------------

  // BALANCE CARD

  // ------------------------------------------------------------

  // ------------------------------------------------------------

  // EMPTY HISTORY

  // ------------------------------------------------------------

  Widget _buildEmptyHistory() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(30),

        child: Column(
          children: [
            Icon(
              Icons.receipt_long_outlined,

              size: 48,

              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),

            const SizedBox(height: 12),

            Text(
              _selectedHistorySection == 'purchases'
                  ? 'No sales yet'
                  : _selectedHistorySection == 'payments'
                  ? 'No payments received yet'
                  : 'No sales returns yet',

              style: TextStyle(
                fontSize: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Ledger filters: All / New Purchase / Payment Received / Sales.
  Widget _buildLedgerFilterSelector() {
    const filters = <String>[
      'All',
      'New Sale',
      'Payment Received',
      'Payment Refused',
      'Sales',
    ];
    return SydexChoiceChips(
      options: filters,
      selected: filters.contains(_selectedLedgerFilter)
          ? _selectedLedgerFilter
          : 'All',
      onSelected: (filter) => setState(() => _selectedLedgerFilter = filter),
    );
  }

  List<Map<String, dynamic>> _filteredLedgerEntries(
    List<Map<String, dynamic>> entries,
  ) {
    switch (_selectedLedgerFilter) {
      case 'New Sale':
        return entries
            .where(
              (entry) =>
                  entry['entry_type']?.toString().toLowerCase() == 'purchase',
            )
            .toList();
      case 'Payment Received':
        return entries.where((entry) {
          final type = entry['entry_type']?.toString().toLowerCase();
          return type == 'payment' ||
              type == 'bounced_check' ||
              entry['is_bounced'] == true;
        }).toList();
      case 'Payment Refused':
        return entries
            .where((entry) => entry['entry_type']?.toString() == 'refusal')
            .toList();
      case 'Sales':
        return entries.where((entry) {
          final type = entry['entry_type']?.toString().toLowerCase();
          return type == 'sale' ||
              type == 'sales' ||
              type == 'return' ||
              type == 'sales_return';
        }).toList();
      case 'All':
      default:
        return entries;
    }
  }

  // ------------------------------------------------------------

  // LEDGER ENTRY

  // ------------------------------------------------------------

  Widget _buildLedgerEntry(Map<String, dynamic> entry) {
    final type = entry['entry_type']?.toString() ?? '';

    final isPurchase = type == 'purchase';

    final isReturn = type == 'return';
    final isRefusal = type == 'refusal';

    final isBouncedCheck = type == 'bounced_check';

    final paymentMethod =
        entry['payment_method']?.toString() ??
        (type == 'payment' ? 'cash' : '');

    final paymentMethodNote = entry['payment_method_note']?.toString() ?? '';
    // The stored split ("Split amounts: cash=…") is shown as its own row, so
    // only the hand-written part of the note is shown as a note.
    final methodNoteText = PaymentMethodBreakdown.noteText(paymentMethodNote);
    final displayedPaymentMethod =
        PaymentMethodBreakdown.display(paymentMethodNote) ??
        _paymentMethodLabel(paymentMethod);

    final amount = (entry['amount'] as num?)?.toDouble() ?? 0;

    final discount = (entry['discount'] as num?)?.toDouble() ?? 0;

    final amountReceived = entry['is_bounced'] == true
        ? 0.0
        : (entry['amount_received'] as num?)?.toDouble() ?? (amount - discount);
    final displayedAmount = type == 'payment' ? amountReceived : amount;

    final balanceBefore = (entry['balance_before'] as num?)?.toDouble() ?? 0;

    final balanceAfter = (entry['balance_after'] as num?)?.toDouble() ?? 0;

    final notes = entry['notes']?.toString() ?? '';

    final profile = entry['profiles'];

    final receivedBy = profile is Map
        ? profile['name']?.toString() ?? 'User'
        : 'User';

    return GestureDetector(
      onLongPress: () {
        if (_isOwner && !isRefusal && mounted) {
          setState(() {
            _selectingHistory = true;
            final id = entry['id']?.toString();
            if (id != null && id.isNotEmpty) _selectedHistoryIds.add(id);
          });
        }
      },
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
          color: isRefusal ? SydexColors.refusedTint(context) : null,
        shape: isRefusal
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: SydexColors.refused(context),
                  width: 1.5,
                ),
              )
            : null,

        child: Padding(
          padding: const EdgeInsets.all(16),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Row(
                children: [
                  if (_selectingHistory)
                    Checkbox(
                      value: _selectedHistoryIds.contains(
                        entry['id']?.toString(),
                      ),
                      onChanged: (selected) {
                        final id = entry['id']?.toString();
                        if (id == null || id.isEmpty) return;
                        setState(() {
                          if (selected == true) {
                            _selectedHistoryIds.add(id);
                          } else {
                            _selectedHistoryIds.remove(id);
                          }
                        });
                      },
                    ),
                  CircleAvatar(
                    radius: 21,
                    backgroundColor: isRefusal
                        ? SydexColors.refused(context)
                        : null,

                    child: Icon(
                      isRefusal
                          ? Icons.block_outlined
                          : isPurchase
                          ? Icons.shopping_cart_outlined
                          : isReturn
                          ? Icons.assignment_return_outlined
                          : Icons.payments_outlined,
                      color: isRefusal
                          ? Theme.of(context).colorScheme.onError
                          : null,
                    ),
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [
                        Text(
                          isRefusal
                              ? 'Payment Refused'
                              : isPurchase
                              ? 'New Sale'
                              : isReturn
                              ? 'Sales Return'
                              : isBouncedCheck
                              ? 'Cheque Bounced'
                              : entry['is_bounced'] == true
                              ? 'Payment Received (Bounced)'
                              : 'Payment Received',

                          style: TextStyle(
                            fontSize: 17,

                            fontWeight: FontWeight.w600,
                            color: isRefusal
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),

                        const SizedBox(height: 3),

                        Text(
                          _formatDate(entry['transaction_date']),

                          style: TextStyle(
                            fontSize: 12,

                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),

                        const SizedBox(height: 4),

                        Text(
                          isRefusal
                              ? CurrencyFormatter.currentAmountDue(
                                  currentBalance,
                                )
                              : isPurchase || isBouncedCheck
                              ? '+${_money(displayedAmount)}'
                              : '-${_money(displayedAmount)}',
                          style: TextStyle(
                            fontSize: isRefusal ? 14 : 18,
                            fontWeight: FontWeight.w600,
                            color:
                                isRefusal ||
                                    isPurchase ||
                                    isBouncedCheck ||
                                    entry['is_bounced'] == true
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (isPurchase && _isOwner)
                    PopupMenuButton<String>(
                      tooltip: 'Sale options',
                      onSelected: (value) {
                        if (value == 'edit') {
                          _editPurchase(entry);
                        } else if (value == 'delete_accidental' ||
                            value == 'remove_paid') {
                          _deletePurchase(entry);
                        } else if (value == 'hide') {
                          _hideHistoryEntry(entry);
                        }
                      },
                      itemBuilder: (context) {
                        final isPaid = _isPurchaseFullyPaid(entry);
                        final isAccidental = _isAccidentalPurchase(entry);

                        return [
                          const PopupMenuItem<String>(
                            value: 'edit',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Edit Sale'),
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: isPaid ? 'remove_paid' : 'delete_accidental',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.delete_outline),
                              title: Text(
                                isPaid
                                    ? 'Remove Paid Sale'
                                    : isAccidental
                                    ? 'Delete Accidental Sale'
                                    : 'Delete Sale',
                              ),
                            ),
                          ),
                        ];
                      },
                    ),

                  if (isReturn && _isOwner)
                    PopupMenuButton<String>(
                      tooltip: 'Sales return options',
                      onSelected: (value) {
                        if (value == 'hide') {
                          _hideHistoryEntry(entry);
                        } else if (value == 'edit') {
                          _editReturn(entry);
                        } else if (value == 'delete') {
                          _deleteSalesReturn(entry);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.edit_outlined), title: Text('Edit sales return')),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.delete_outline), title: Text('Delete sales return')),
                        ),
                      ],
                    ),

                  if (_isOwner &&
                      type == 'payment' &&
                      entry['is_bounced'] != true)
                    IconButton(
                      tooltip: 'Edit received payment',
                      onPressed: () => _editReceivedPayment(entry),
                      icon: const Icon(Icons.edit_outlined),
                    ),

                  if (_isOwner &&
                      (isBouncedCheck ||
                          (type == 'payment' && entry['is_bounced'] == true)))
                    IconButton(
                      tooltip: 'Change date',
                      onPressed: () => _changeEntryDate(entry),
                      icon: const Icon(Icons.edit_calendar_outlined),
                    ),

                  if (_isOwner &&
                      type == 'payment' &&
                      entry['is_bounced'] != true)
                    IconButton(
                      tooltip: 'Delete payment',
                      onPressed: () => _deleteReceivedPayment(entry),
                      icon: const Icon(Icons.delete_outline),
                    ),

                  if (!isPurchase &&
                      !isReturn &&
                      !isBouncedCheck &&
                      paymentMethod == 'cheque')
                    PopupMenuButton<String>(
                      tooltip: 'Payment options',
                      onSelected: (value) {
                        if (value == 'bounce') {
                          _markChequeBounced(entry);
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem<String>(
                          value: 'bounce',
                          enabled: entry['is_bounced'] != true,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.money_off_csred_outlined),
                            title: Text(
                              entry['is_bounced'] == true
                                  ? 'Cheque Already Bounced'
                                  : 'Mark Cheque as Bounced',
                            ),
                          ),
                        ),
                      ],
                    ),

                ],
              ),

              const Divider(height: 24),

              if (isRefusal) ...[
                _detailRow(
                  'Visit date',
                  _formatDate(
                    entry['status_date'] ?? entry['transaction_date'],
                  ),
                ),
                const SizedBox(height: 8),
                _detailRow('Outcome', 'Customer refused payment'),
                const SizedBox(height: 8),
                _detailRow(
                  'Current amount due',
                  _money(currentBalance < 0 ? 0 : currentBalance),
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _detailRow('Note', notes),
                ],
              ] else if (isPurchase) ...[
                _detailRow('Original Amount', _money(amount + discount)),

                const SizedBox(height: 8),

                _detailRow('Amount After Discount', _money(amount)),

                if (discount > 0) ...[
                  const SizedBox(height: 8),

                  _detailRow('Discount Given', _money(discount)),
                ],

                const SizedBox(height: 8),

                _detailRow('Old balance', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow(
                  balanceAfter < 0 ? 'Advance' : 'New balance',
                  _money(balanceAfter.abs()),
                ),
              ] else if (isBouncedCheck) ...[
                _detailRow(
                  'Cheque Amount Returned to Due',
                  _money(
                    amount - ((entry['bank_charge'] as num?)?.toDouble() ?? 0),
                  ),
                ),

                const SizedBox(height: 8),

                _detailRow(
                  'Bank Charges',
                  _money((entry['bank_charge'] as num?)?.toDouble() ?? 0),
                ),

                const SizedBox(height: 8),

                _detailRow('Total Added to Due', _money(amount)),

                const SizedBox(height: 8),

                _detailRow('Old balance', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow(
                  balanceAfter < 0 ? 'Advance' : 'New balance',
                  _money(balanceAfter.abs()),
                ),
              ] else if (isReturn) ...[
                _detailRow('Returned Amount', _money(amount)),

                const SizedBox(height: 8),

                _detailRow('Old balance', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow(
                  balanceAfter < 0 ? 'Advance' : 'New balance',
                  _money(balanceAfter.abs()),
                ),
              ] else ...[
                _detailRow('Amount Settled', _money(amount)),

                const SizedBox(height: 8),

                _detailRow('Discount Given', _money(discount)),

                const SizedBox(height: 8),

                _detailRow('Actually Received', _money(amountReceived)),

                const SizedBox(height: 8),

                _detailRow('Payment Method', displayedPaymentMethod),

                if (PaymentMethodBreakdown.display(paymentMethodNote)
                    case final splitDetails?) ...[
                  const SizedBox(height: 8),
                  _detailRow('Payment Split', splitDetails),
                ],

                if (methodNoteText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _detailRow('Payment Method Note', methodNoteText),
                ],

                const SizedBox(height: 8),

                _detailRow('Received By', receivedBy),

                const SizedBox(height: 8),

                _detailRow('Old balance', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow(
                  balanceAfter < 0 ? 'Advance' : 'New balance',
                  _money(balanceAfter.abs()),
                ),
              ],

              if (notes.isNotEmpty && !isRefusal) ...[
                const SizedBox(height: 14),

                Container(
                  width: double.infinity,

                  padding: const EdgeInsets.all(12),

                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,

                    borderRadius: BorderRadius.circular(8),
                  ),

                  child: Text('Note: $notes'),
                ),
              ],

              if (!isPurchase &&
                  entry['signature_path'] != null &&
                  entry['signature_path'].toString().isNotEmpty) ...[
                const SizedBox(height: 12),

                _SignaturePreview(
                  signaturePath: entry['signature_path'].toString(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------

  // DETAIL ROW

  // ------------------------------------------------------------

  Widget _detailRow(String title, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),

        const SizedBox(width: 12),

        Expanded(
          flex: 3,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

// ============================================================

// SIGNATURE PREVIEW

// ============================================================

class _SignaturePreview extends StatefulWidget {
  final String signaturePath;

  const _SignaturePreview({required this.signaturePath});

  @override
  State<_SignaturePreview> createState() => _SignaturePreviewState();
}

class _SignaturePreviewState extends State<_SignaturePreview> {
  Uint8List? signatureBytes;

  bool isLoading = true;

  @override
  void initState() {
    super.initState();

    _loadSignature();
  }

  Future<void> _loadSignature() async {
    final bytes = await TransactionService.downloadSignature(
      widget.signaturePath,
    );

    if (!mounted) return;

    setState(() {
      signatureBytes = bytes;

      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.all(8),

        child: SizedBox(
          height: 40,

          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    if (signatureBytes == null || signatureBytes!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        const Text(
          'Signature',

          style: TextStyle(fontWeight: FontWeight.w600),
        ),

        const SizedBox(height: 8),

        Container(
          height: 120,

          width: double.infinity,

          padding: const EdgeInsets.all(8),

          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),

            borderRadius: BorderRadius.circular(8),
          ),

          child: Image.memory(signatureBytes!, fit: BoxFit.contain),
        ),
      ],
    );
  }
}
