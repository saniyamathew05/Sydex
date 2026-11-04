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
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/transaction_service.dart';
import '../../services/payment_receipt_share_service.dart';
import '../../services/payment_method_breakdown.dart';

import '../payments/payment_screen.dart';

import '../purchases/add_purchase_screen.dart';
import '../../services/currency_formatter.dart';

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

  String get _hiddenHistoryKey =>
      'customer_details_hidden_history_${widget.customer.id}';

  Future<void> _loadHiddenHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _hiddenHistoryIds.addAll(
        prefs.getStringList(_hiddenHistoryKey) ?? const [],
      );
    });
  }

  Future<void> _hideHistoryEntry(Map<String, dynamic> entry) async {
    final id = entry['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() => _hiddenHistoryIds.add(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenHistoryKey, _hiddenHistoryIds.toList());
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
    setState(() => _hiddenHistoryIds.addAll(selected));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenHistoryKey, _hiddenHistoryIds.toList());
  }

  Future<void> _finishHistorySelection() async {
    if (_selectedHistoryIds.isNotEmpty) {
      setState(() {
        _hiddenHistoryIds.addAll(_selectedHistoryIds);
        _selectedHistoryIds.clear();
        _selectingHistory = false;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_hiddenHistoryKey, _hiddenHistoryIds.toList());
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
        final amountReceived =
            (entry['amount_received'] as num?)?.toDouble() ??
            (amount - discount);

        if (type == 'purchase') {
          totalPurchases += amount;
          totalDiscount += discount;
        } else if (type == 'payment') {
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
                    _pdfSummaryItem('Balance Due', _money(currentBalance)),
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
                  final received =
                      (entry['amount_received'] as num?)?.toDouble() ??
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
                    _money(balanceAfter),
                    receivedBy,
                  ];
                }).toList(),
              ),
              pw.SizedBox(height: 18),
              pw.Text(
                'Current Amount Due: ${_money(currentBalance)}',
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
        builder: (_) => PaymentScreen(customer: _displayCustomer),
      ),
    );

    await _refreshCustomerData();
  }

  Future<void> _editReceivedPayment(Map<String, dynamic> entry) async {
    final paymentId = entry['id']?.toString();
    if (paymentId == null || paymentId.isEmpty) return;

    final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
    final discount = (entry['discount'] as num?)?.toDouble() ?? 0;
    final amountController = TextEditingController(
      text: amount.toStringAsFixed(2),
    );
    final discountController = TextEditingController(
      text: discount.toStringAsFixed(2),
    );
    final notesController = TextEditingController(
      text: entry['notes']?.toString() ?? '',
    );
    final methodNoteController = TextEditingController(
      text: entry['payment_method_note']?.toString() ?? '',
    );
    var method = (entry['payment_method']?.toString() ?? 'cash').toLowerCase();
    const methods = ['cash', 'cheque', 'neft', 'gpay'];
    if (!methods.contains(method)) method = 'cash';
    final formKey = GlobalKey<FormState>();
    DateTime paymentDate;
    try {
      paymentDate = DateTime.parse(
        entry['transaction_date'].toString(),
      ).toLocal();
    } catch (_) {
      paymentDate = DateTime.now();
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit received payment'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Settlement amount (₹)',
                      ),
                      validator: (value) {
                        final parsed = double.tryParse((value ?? '').trim());
                        return parsed == null || parsed <= 0
                            ? 'Enter an amount greater than zero'
                            : null;
                      },
                    ),
                    TextFormField(
                      controller: discountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Discount (₹)',
                      ),
                      validator: (value) {
                        final parsed = double.tryParse((value ?? '').trim());
                        final enteredAmount =
                            double.tryParse(amountController.text.trim()) ?? 0;
                        return parsed == null ||
                                parsed < 0 ||
                                parsed >= enteredAmount
                            ? 'Discount must be less than amount'
                            : null;
                      },
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: dialogContext,
                          initialDate: paymentDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                          helpText: 'Select payment date',
                        );
                        if (picked != null) {
                          setDialogState(() {
                            paymentDate = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              paymentDate.hour,
                              paymentDate.minute,
                              paymentDate.second,
                            );
                          });
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Payment Date',
                          prefixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                        child: Text(_formatDate(paymentDate)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: method,
                      decoration: const InputDecoration(
                        labelText: 'Payment method',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'cash', child: Text('Cash')),
                        DropdownMenuItem(
                          value: 'cheque',
                          child: Text('Cheque'),
                        ),
                        DropdownMenuItem(value: 'neft', child: Text('NEFT')),
                        DropdownMenuItem(
                          value: 'gpay',
                          child: Text('GPay / Online'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => method = value);
                      },
                    ),
                    TextFormField(
                      controller: methodNoteController,
                      decoration: const InputDecoration(
                        labelText: 'Payment method note',
                      ),
                    ),
                    TextFormField(
                      controller: notesController,
                      decoration: const InputDecoration(labelText: 'Notes'),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(dialogContext, {
                  'amount': double.parse(amountController.text.trim()),
                  'discount': double.parse(discountController.text.trim()),
                  'notes': notesController.text,
                  'method': method,
                  'methodNote': methodNoteController.text,
                  'transactionDate': paymentDate,
                });
              },
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    discountController.dispose();
    notesController.dispose();
    methodNoteController.dispose();
    if (result == null || !mounted) return;

    final success = await TransactionService.updatePayment(
      paymentId: paymentId,
      amount: result['amount'] as double,
      discount: result['discount'] as double,
      notes: result['notes'] as String,
      paymentMethod: result['method'] as String,
      paymentMethodNote: result['methodNote'] as String,
      transactionDate: result['transactionDate'] as DateTime,
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

    if (!isPaid && !isAccidental) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This purchase has a payment recorded. It can be removed only after it has been fully paid.',
          ),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(isPaid ? 'Remove Paid Sale?' : 'Delete Accidental Sale?'),
          content: Text(
            isPaid
                ? 'This purchase has already been fully paid. It will be removed from the customer transaction history. The payment records will remain unchanged.'
                : 'This purchase has no payment recorded after it. It looks like an accidental purchase entry. Delete it permanently from the customer transaction history?',
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
                      currentBalance < 0
                          ? 'Owed to customer'
                          : 'Current Amount Due',
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

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(
            Icons.arrow_back,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          customer.businessName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        actions: [
          if (_isOwner)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: OutlinedButton.icon(
                onPressed: _editCustomer,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshCustomerData,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
                    children: [
                      // Compact customer identity and outstanding balance header.
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 23,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              child: Text(
                                customer.businessName.trim().isEmpty
                                    ? '?'
                                    : customer.businessName
                                          .trim()[0]
                                          .toUpperCase(),
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    customer.businessName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.location_on_outlined,
                                        size: 14,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          customer.location,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.phone_outlined,
                                        size: 13,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          customer.phone,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 30,
                                              height: 28,
                                            ),
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Call customer',
                                        onPressed: _callCustomer,
                                        icon: Icon(
                                          Icons.call_outlined,
                                          size: 16,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 30,
                                              height: 28,
                                            ),
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Open customer WhatsApp chat',
                                        onPressed: _whatsappCustomer,
                                        icon: const Icon(
                                          Icons.chat_outlined,
                                          size: 16,
                                          color: Color(0xFF159A69),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Share payment receipt',
                                        visualDensity: VisualDensity.compact,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 30,
                                              height: 28,
                                            ),
                                        padding: EdgeInsets.zero,
                                        onPressed: _sharingReceipt
                                            ? null
                                            : _shareCustomerReceipt,
                                        icon: const Icon(
                                          Icons.receipt_long_outlined,
                                          size: 16,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              constraints: const BoxConstraints(minWidth: 94),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFEEF0),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    currentBalance < 0
                                        ? 'Owed to customer'
                                        : 'Total Due',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF8D5962),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _money(currentBalance.abs()),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFFB4232F),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Tabs arranged like the supplied reference: Ledger / Details / Purchases / Photos.
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            _customerTab('Ledger', 'ledger'),
                            _customerTab('Details', 'details'),
                            _customerTab('Sales', 'purchases'),
                            _customerTab('Photos', 'photos'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_activeTab == 'ledger') ...[
                        _buildLedgerFilterSelector(),
                        if (_selectingHistory)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _finishHistorySelection,
                              child: Text(
                                'Finish selection (${_selectedHistoryIds.length})',
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        _buildLedgerTableHeader(),
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
                        _sectionHeading('Customer Signatures & Photos', 0),
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
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
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
                      child: SizedBox(
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed: _recordPayment,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Payment', maxLines: 1),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF18A66A),
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.surface,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed: _newPurchase,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Sale', maxLines: 1),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.surface,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _customerTab(String label, String value) {
    final selected = _activeTab == value;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() => _activeTab = value),
        onLongPress: value == 'ledger'
            ? () => setState(() => _selectingHistory = true)
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border(
                    bottom: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLedgerTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              'Date',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'Description',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Amount',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Balance',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
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
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _detailRow('Business name', customer.businessName),
          _detailRow('Location', customer.location),
          _detailRow('Phone number', customer.phone),
          _detailRow('Opening balance', _money(customer.openingBalance)),
          const Divider(height: 22),
          _detailRow(
            currentBalance < 0 ? 'Owed to customer' : 'Current balance',
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
              fontWeight: FontWeight.w800,
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
        Icon(Icons.photo_library_outlined, size: 38, color: Color(0xFF9A96B6)),
        SizedBox(height: 8),
        Text(
          'No customer signatures or photos yet',
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

              color: Theme.of(context).colorScheme.outline,
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
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: filters.map((filter) {
            final selected = _selectedLedgerFilter == filter;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                label: Text(filter),
                selected: selected,
                showCheckmark: false,
                onSelected: (_) {
                  setState(() => _selectedLedgerFilter = filter);
                },
                backgroundColor: Theme.of(context).colorScheme.surface,
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                side: BorderSide(
                  color: selected
                      ? const Color(0xFFB9A9FF)
                      : Theme.of(context).colorScheme.outlineVariant,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            );
          }).toList(),
        ),
      ),
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
    final displayedPaymentMethod =
        PaymentMethodBreakdown.display(paymentMethodNote) ??
        _paymentMethodLabel(paymentMethod);

    final amount = (entry['amount'] as num?)?.toDouble() ?? 0;

    final discount = (entry['discount'] as num?)?.toDouble() ?? 0;

    final amountReceived =
        (entry['amount_received'] as num?)?.toDouble() ?? (amount - discount);

    final balanceBefore = (entry['balance_before'] as num?)?.toDouble() ?? 0;

    final balanceAfter = (entry['balance_after'] as num?)?.toDouble() ?? 0;

    final notes = entry['notes']?.toString() ?? '';

    final profile = entry['profiles'];

    final receivedBy = profile is Map
        ? profile['name']?.toString() ?? 'User'
        : 'User';

    return GestureDetector(
      onLongPress: () {
        if (!_selectingHistory) {
          setState(() => _selectingHistory = true);
        }
      },
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: isRefusal ? Theme.of(context).colorScheme.errorContainer : null,
        shape: isRefusal
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.error,
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
                        ? Theme.of(context).colorScheme.error
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

                            fontWeight: FontWeight.bold,
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
                            value: 'delete_accidental',
                            enabled: isAccidental,
                            child: const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.delete_outline),
                              title: Text('Delete Accidental Sale'),
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'remove_paid',
                            enabled: isPaid,
                            child: const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.remove_circle_outline),
                              title: Text('Remove Paid Sale'),
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
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem<String>(
                          value: 'hide',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.visibility_off_outlined),
                            title: Text('Remove from customer history'),
                          ),
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

                  Text(
                    isPurchase || isBouncedCheck
                        ? '+${_money(amount)}'
                        : '-${_money(amount)}',

                    style: TextStyle(
                      fontSize: 18,

                      fontWeight: FontWeight.bold,

                      color:
                          isRefusal ||
                              isPurchase ||
                              isBouncedCheck ||
                              entry['is_bounced'] == true
                          ? Colors.red
                          : Colors.green,
                    ),
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

                _detailRow('Balance Before', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow(
                  balanceAfter < 0 ? 'Advance' : 'Balance After',
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

                _detailRow('Balance Before', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow('Balance After', _money(balanceAfter)),
              ] else if (isReturn) ...[
                _detailRow('Returned Amount', _money(amount)),

                const SizedBox(height: 8),

                _detailRow('Balance Before', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow('Balance After', _money(balanceAfter)),
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

                if (paymentMethodNote.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _detailRow('Payment Method Note', paymentMethodNote),
                ],

                const SizedBox(height: 8),

                _detailRow('Received By', receivedBy),

                const SizedBox(height: 8),

                _detailRow('Balance Before', _money(balanceBefore)),

                const SizedBox(height: 8),

                _detailRow('Balance After', _money(balanceAfter)),
              ],

              if (notes.isNotEmpty) ...[
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
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),

        Text(value, style: TextStyle(fontWeight: FontWeight.w600)),
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
          'Customer Signature',

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
