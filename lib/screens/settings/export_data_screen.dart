import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ExportDataScreen extends StatefulWidget {
  const ExportDataScreen({super.key});

  @override
  State<ExportDataScreen> createState() => _ExportDataScreenState();
}

class _ExportDataScreenState extends State<ExportDataScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isExporting = false;

  Future<void> _exportCustomers() async {
    setState(() {
      _isExporting = true;
    });

    try {
      final customers = await _supabase
          .from('customers')
          .select()
          .order('business_name', ascending: true);

      final buffer = StringBuffer();

      buffer.writeln(
        'Business Name,Location,Phone,Opening Balance,Active,Created At',
      );

      for (final customer in customers) {
        buffer.writeln(
          [
            _csv(customer['business_name']),

            _csv(customer['location']),

            _csv(customer['phone']),

            _csv(customer['opening_balance']?.toString()),

            _csv(customer['is_active']?.toString()),

            _csv(customer['created_at']?.toString()),
          ].join(','),
        );
      }

      await _shareCsv(filename: 'customers.csv', content: buffer.toString());
    } catch (error) {
      _showSnackBar('Could not export customers.');
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _exportPayments() async {
    setState(() {
      _isExporting = true;
    });

    try {
      final payments = await _supabase
          .from('payments')
          .select()
          .order('transaction_date', ascending: false);

      final buffer = StringBuffer();

      buffer.writeln(
        'Transaction ID,Customer ID,User ID,Amount,Previous Balance,Remaining Balance,Transaction Date,Notes',
      );

      for (final payment in payments) {
        buffer.writeln(
          [
            _csv(payment['id']?.toString()),

            _csv(payment['customer_id']?.toString()),

            _csv(payment['user_id']?.toString()),

            _csv(payment['amount']?.toString()),

            _csv(payment['previous_balance']?.toString()),

            _csv(payment['remaining_balance']?.toString()),

            _csv(payment['transaction_date']?.toString()),

            _csv(payment['notes']?.toString()),
          ].join(','),
        );
      }

      await _shareCsv(filename: 'payments.csv', content: buffer.toString());
    } catch (error) {
      _showSnackBar('Could not export payments.');
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _exportEverything() async {
    setState(() {
      _isExporting = true;
    });

    try {
      final customers = await _supabase
          .from('customers')
          .select()
          .order('business_name', ascending: true);

      final payments = await _supabase
          .from('payments')
          .select()
          .order('transaction_date', ascending: false);

      final buffer = StringBuffer();

      buffer.writeln('CUSTOMERS');

      buffer.writeln(
        'Business Name,Location,Phone,Opening Balance,Active,Created At',
      );

      for (final customer in customers) {
        buffer.writeln(
          [
            _csv(customer['business_name']),

            _csv(customer['location']),

            _csv(customer['phone']),

            _csv(customer['opening_balance']?.toString()),

            _csv(customer['is_active']?.toString()),

            _csv(customer['created_at']?.toString()),
          ].join(','),
        );
      }

      buffer.writeln();

      buffer.writeln('PAYMENTS');

      buffer.writeln(
        'Transaction ID,Customer ID,User ID,Amount,Previous Balance,Remaining Balance,Transaction Date,Notes',
      );

      for (final payment in payments) {
        buffer.writeln(
          [
            _csv(payment['id']?.toString()),

            _csv(payment['customer_id']?.toString()),

            _csv(payment['user_id']?.toString()),

            _csv(payment['amount']?.toString()),

            _csv(payment['previous_balance']?.toString()),

            _csv(payment['remaining_balance']?.toString()),

            _csv(payment['transaction_date']?.toString()),

            _csv(payment['notes']?.toString()),
          ].join(','),
        );
      }

      await _shareCsv(
        filename: 'business_payment_export.csv',

        content: buffer.toString(),
      );
    } catch (error) {
      _showSnackBar('Could not export data.');
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  String _csv(dynamic value) {
    final text = value?.toString() ?? '';

    final escaped = text.replaceAll('"', '""');

    return '"$escaped"';
  }

  Future<void> _shareCsv({
    required String filename,

    required String content,
  }) async {
    final bytes = utf8.encode(content);

    final file = XFile.fromData(
      Uint8List.fromList(bytes),

      name: filename,

      mimeType: 'text/csv',
    );

    await SharePlus.instance.share(
      ShareParams(files: [file], subject: filename),
    );
  }

  void _showSnackBar(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Export Data')),

      body: ListView(
        padding: const EdgeInsets.all(20),

        children: [
          Container(
            padding: const EdgeInsets.all(18),

            decoration: BoxDecoration(
              color: colors.primaryContainer,

              borderRadius: BorderRadius.circular(18),
            ),

            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Icon(
                  Icons.file_download_outlined,

                  color: colors.primary,

                  size: 30,
                ),

                const SizedBox(width: 14),

                Expanded(
                  child: Text(
                    'Export your business records as CSV files so you can keep a backup or open them in Excel.',

                    style: TextStyle(
                      color: colors.onPrimaryContainer,

                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 22),

          _ExportCard(
            icon: Icons.people_outline,

            title: 'Export Customers',

            description:
                'Business names, locations, phone numbers and opening balances.',

            onPressed: _isExporting ? null : _exportCustomers,
          ),

          const SizedBox(height: 14),

          _ExportCard(
            icon: Icons.payments_outlined,

            title: 'Export Payments',

            description:
                'Payment amounts, balances, dates, notes and transaction IDs.',

            onPressed: _isExporting ? null : _exportPayments,
          ),

          const SizedBox(height: 14),

          _ExportCard(
            icon: Icons.file_copy_outlined,

            title: 'Export Everything',

            description:
                'Export customer and payment records into one CSV file.',

            onPressed: _isExporting ? null : _exportEverything,
          ),

          if (_isExporting) ...[
            const SizedBox(height: 25),

            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _ExportCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final String description;

  final VoidCallback? onPressed;

  const _ExportCard({
    required this.icon,

    required this.title,

    required this.description,

    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: colors.surface,

        borderRadius: BorderRadius.circular(18),

        border: Border.all(color: colors.outlineVariant),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              Container(
                width: 44,

                height: 44,

                decoration: BoxDecoration(
                  color: colors.primaryContainer,

                  borderRadius: BorderRadius.circular(13),
                ),

                child: Icon(icon, color: colors.primary),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Text(
                  title,

                  style: const TextStyle(
                    fontSize: 16,

                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          Text(
            description,

            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),

          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,

            child: OutlinedButton.icon(
              onPressed: onPressed,

              icon: const Icon(Icons.share_outlined),

              label: const Text('Export & Share'),
            ),
          ),
        ],
      ),
    );
  }
}
