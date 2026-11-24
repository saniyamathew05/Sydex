import 'package:flutter/material.dart';

import '../services/currency_formatter.dart';
import '../services/payment_method_breakdown.dart';

/// Values returned by [showEditPaymentDialog].
class EditedPayment {
  const EditedPayment({
    required this.amount,
    required this.discount,
    required this.notes,
    required this.method,
    required this.methodNote,
    required this.transactionDate,
  });

  final double amount;
  final double discount;
  final String notes;
  final String method;
  final String methodNote;
  final DateTime transactionDate;
}

const _methods = ['cash', 'cheque', 'neft', 'gpay'];

/// Shared editor for a received payment, including split (multi-method)
/// payments. Split amounts are saved in the method note in the same
/// `Split amounts: cash=..;cheque=..` format the payment screen writes.
Future<EditedPayment?> showEditPaymentDialog(
  BuildContext context, {
  required double amount,
  required double discount,
  required String notes,
  required String method,
  required String methodNote,
  required DateTime transactionDate,
  bool dateOnly = false,
}) {
  return showDialog<EditedPayment>(
    context: context,
    builder: (_) => _EditPaymentDialog(
      amount: amount,
      discount: discount,
      notes: notes,
      method: method,
      methodNote: methodNote,
      transactionDate: transactionDate,
      dateOnly: dateOnly,
    ),
  );
}

class _SplitRow {
  _SplitRow(this.method, double amount)
    : controller = TextEditingController(text: amount.toStringAsFixed(2));
  String method;
  final TextEditingController controller;
}

class _EditPaymentDialog extends StatefulWidget {
  const _EditPaymentDialog({
    required this.amount,
    required this.discount,
    required this.notes,
    required this.method,
    required this.methodNote,
    required this.transactionDate,
    required this.dateOnly,
  });

  final double amount;
  final double discount;
  final String notes;
  final String method;
  final String methodNote;
  final DateTime transactionDate;
  final bool dateOnly;

  @override
  State<_EditPaymentDialog> createState() => _EditPaymentDialogState();
}

class _EditPaymentDialogState extends State<_EditPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _discount;
  late final TextEditingController _notes;
  late final TextEditingController _methodNote;
  late String _method;
  late DateTime _date;
  late bool _split;
  final List<_SplitRow> _rows = [];
  String? _splitError;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: widget.amount.toStringAsFixed(2));
    _discount = TextEditingController(
      text: widget.discount.toStringAsFixed(2),
    );
    _notes = TextEditingController(text: widget.notes);
    final parts = PaymentMethodBreakdown.parseOrdered(widget.methodNote);
    _split = parts.length > 1;
    _methodNote = TextEditingController(
      text: parts.isEmpty
          ? widget.methodNote
          : (PaymentMethodBreakdown.additionalNote(widget.methodNote) ?? ''),
    );
    final method = widget.method.trim().toLowerCase();
    _method = _methods.contains(method) ? method : 'cash';
    _date = widget.transactionDate.toLocal();
    for (final part in parts) {
      _rows.add(
        _SplitRow(_methods.contains(part.method) ? part.method : 'cash', part.amount),
      );
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _discount.dispose();
    _notes.dispose();
    _methodNote.dispose();
    for (final row in _rows) {
      row.controller.dispose();
    }
    super.dispose();
  }

  double get _received {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final discount = double.tryParse(_discount.text.trim()) ?? 0;
    return amount - discount;
  }

  void _setSplit(bool enabled) {
    setState(() {
      _split = enabled;
      _splitError = null;
      if (enabled && _rows.isEmpty) {
        final received = _received > 0 ? _received : 0.0;
        _rows
          ..add(_SplitRow(_method, received))
          ..add(_SplitRow(_method == 'cash' ? 'cheque' : 'cash', 0));
      }
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amount.text.trim());
    final discount = double.parse(_discount.text.trim());
    final extraNote = _methodNote.text.trim();
    var method = _method;
    var methodNote = extraNote;

    if (_split && !widget.dateOnly) {
      final used = <String>{};
      final parts = <({String method, double amount})>[];
      for (final row in _rows) {
        final value = double.tryParse(row.controller.text.trim());
        if (value == null || value <= 0) {
          setState(() => _splitError = 'Every method needs an amount above zero.');
          return;
        }
        if (!used.add(row.method)) {
          setState(() => _splitError = 'Use each payment method only once.');
          return;
        }
        parts.add((method: row.method, amount: value));
      }
      if (parts.length < 2) {
        setState(() => _splitError = 'Add at least two methods, or turn split off.');
        return;
      }
      final total = parts.fold<double>(0, (sum, part) => sum + part.amount);
      final received = amount - discount;
      if ((total - received).abs() >= 0.01) {
        setState(
          () => _splitError =
              'Method amounts add up to ${CurrencyFormatter.rupees(total)} but '
              '${CurrencyFormatter.rupees(received)} was received.',
        );
        return;
      }
      method = parts.first.method;
      final breakdown =
          '${PaymentMethodBreakdown.marker} ${parts.map((p) => '${p.method}=${p.amount.toStringAsFixed(2)}').join(';')}';
      methodNote = extraNote.isEmpty ? breakdown : '$breakdown • $extraNote';
    } else if (widget.dateOnly) {
      methodNote = widget.methodNote;
      method = widget.method;
    }

    Navigator.pop(
      context,
      EditedPayment(
        amount: amount,
        discount: discount,
        notes: widget.dateOnly ? widget.notes : _notes.text,
        method: method,
        methodNote: methodNote,
        transactionDate: _date,
      ),
    );
  }

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  List<DropdownMenuItem<String>> get _methodItems => [
    for (final method in _methods)
      DropdownMenuItem(
        value: method,
        child: Text(PaymentMethodBreakdown.methodLabel(method)),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final editable = !widget.dateOnly;
    return AlertDialog(
      title: Text(editable ? 'Edit received payment' : 'Change payment date'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (editable) ...[
                  TextFormField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Settlement amount (₹)',
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final parsed = double.tryParse((value ?? '').trim());
                      return parsed == null || parsed <= 0
                          ? 'Enter an amount greater than zero'
                          : null;
                    },
                  ),
                  TextFormField(
                    controller: _discount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Discount (₹)'),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final parsed = double.tryParse((value ?? '').trim());
                      final amount = double.tryParse(_amount.text.trim()) ?? 0;
                      return parsed == null || parsed < 0 || parsed >= amount
                          ? 'Discount must be less than amount'
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      helpText: 'Select payment date',
                    );
                    if (picked != null) {
                      setState(() {
                        _date = DateTime(
                          picked.year,
                          picked.month,
                          picked.day,
                          _date.hour,
                          _date.minute,
                          _date.second,
                        );
                      });
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Payment date',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                    child: Text(_formatDate(_date)),
                  ),
                ),
                if (editable) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Paid with more than one method'),
                    value: _split,
                    onChanged: _setSplit,
                  ),
                  if (!_split)
                    DropdownButtonFormField<String>( isExpanded: true,
                      initialValue: _method,
                      decoration: const InputDecoration(
                        labelText: 'Payment method',
                      ),
                      items: _methodItems,
                      onChanged: (value) {
                        if (value != null) setState(() => _method = value);
                      },
                    )
                  else ...[
                    for (var i = 0; i < _rows.length; i++)
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>( isExpanded: true,
                              key: ObjectKey(_rows[i]),
                              initialValue: _rows[i].method,
                              decoration: const InputDecoration(
                                labelText: 'Method',
                              ),
                              items: _methodItems,
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _rows[i].method = value);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _rows[i].controller,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Amount (₹)',
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove method',
                            onPressed: _rows.length <= 2
                                ? null
                                : () => setState(() {
                                    _rows.removeAt(i).controller.dispose();
                                  }),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ],
                      ),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: _rows.length >= _methods.length
                              ? null
                              : () => setState(() {
                                  final unused = _methods.firstWhere(
                                    (m) => !_rows.any((row) => row.method == m),
                                    orElse: () => 'cash',
                                  );
                                  _rows.add(_SplitRow(unused, 0));
                                }),
                          icon: const Icon(Icons.add),
                          label: const Text('Add method'),
                        ),
                        const Spacer(),
                        Text(
                          'Received: ${CurrencyFormatter.rupees(_received)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    if (_splitError != null)
                      Text(
                        _splitError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                  TextFormField(
                    controller: _methodNote,
                    decoration: const InputDecoration(
                      labelText: 'Payment method note',
                      hintText: 'Cheque number, UPI reference…',
                    ),
                  ),
                  TextFormField(
                    controller: _notes,
                    decoration: const InputDecoration(labelText: 'Notes'),
                    maxLines: 2,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save changes')),
      ],
    );
  }
}
