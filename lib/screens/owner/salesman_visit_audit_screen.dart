import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class SalesmanVisitAuditScreen extends StatefulWidget {
  const SalesmanVisitAuditScreen({super.key});

  @override
  State<SalesmanVisitAuditScreen> createState() =>
      _SalesmanVisitAuditScreenState();
}

class _SalesmanVisitAuditScreenState extends State<SalesmanVisitAuditScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _visits = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final audit = await _db
          .from('salesman_visit_audit')
          .select('status_id,latitude,longitude,accuracy_meters,captured_at')
          .order('captured_at', ascending: false)
          .limit(200);
      final auditRows = List<Map<String, dynamic>>.from(audit);
      if (auditRows.isEmpty) {
        if (mounted) {
          setState(() {
            _visits = [];
            _loading = false;
          });
        }
        return;
      }
      final statusIds = auditRows
          .map((e) => e['status_id'].toString())
          .toList();
      final statuses = await _db
          .from('salesman_customer_daily_status')
          .select(
            'id,customer_id,status,status_date,entered_by,note,created_at',
          )
          .inFilter('id', statusIds);
      final statusRows = List<Map<String, dynamic>>.from(statuses);
      final customerIds = statusRows
          .map((e) => e['customer_id'].toString())
          .toSet()
          .toList();
      final userIds = statusRows
          .map((e) => e['entered_by'].toString())
          .toSet()
          .toList();
      final customers = customerIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await _db
                  .from('customers')
                  .select('id,business_name,location,phone')
                  .inFilter('id', customerIds),
            );
      final profiles = userIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await _db
                  .from('profiles')
                  .select('id,name')
                  .inFilter('id', userIds),
            );
      final statusById = {
        for (final row in statusRows) row['id'].toString(): row,
      };
      final customerById = {
        for (final row in customers) row['id'].toString(): row,
      };
      final profileById = {
        for (final row in profiles) row['id'].toString(): row,
      };
      final result = <Map<String, dynamic>>[];
      for (final auditRow in auditRows) {
        final status = statusById[auditRow['status_id'].toString()];
        if (status == null) continue;
        result.add({
          ...auditRow,
          'status': status['status'],
          'status_date': status['status_date'],
          'note': status['note'],
          'customer': customerById[status['customer_id'].toString()] ?? {},
          'salesman': profileById[status['entered_by'].toString()] ?? {},
        });
      }
      if (mounted) {
        setState(() {
          _visits = result;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _openMap(Map<String, dynamic> row) async {
    final lat = (row['latitude'] as num).toDouble();
    final lon = (row['longitude'] as num).toDouble();
    final uri = Uri.parse('https://maps.google.com/?q=$lat,$lon');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open Maps.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Salesman visit audit'),
        actions: [
          IconButton(
            onPressed: _load,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          : _visits.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_searching, size: 48),
                    SizedBox(height: 12),
                    Text(
                      'No visit records yet',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'When a salesman records a payment or refusal, the captured location will appear here.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _visits.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final row = _visits[index];
                  final customer = Map<String, dynamic>.from(
                    row['customer'] as Map,
                  );
                  final salesman = Map<String, dynamic>.from(
                    row['salesman'] as Map,
                  );
                  final rejected = row['status'] == 'rejected';
                  final timestamp = DateTime.tryParse(
                    row['captured_at']?.toString() ?? '',
                  )?.toLocal();
                  final accuracy = (row['accuracy_meters'] as num?)?.toDouble();
                  return Card(
                    elevation: 0,
                    color: colors.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      customer['business_name']?.toString() ??
                                          'Unknown customer',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      customer['location']?.toString() ?? '',
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Chip(
                                avatar: Icon(
                                  rejected ? Icons.block : Icons.check_circle,
                                  size: 16,
                                  color: rejected
                                      ? colors.error
                                      : colors.primary,
                                ),
                                label: Text(
                                  rejected ? 'No payment' : 'Payment recorded',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Recorded by: ${salesman['name'] ?? 'Salesman'}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            timestamp == null
                                ? 'Time unavailable'
                                : '${timestamp.day.toString().padLeft(2, '0')}/${timestamp.month.toString().padLeft(2, '0')}/${timestamp.year}  ${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'GPS: ${(row['latitude'] as num).toStringAsFixed(6)}, ${(row['longitude'] as num).toStringAsFixed(6)}',
                          ),
                          if (accuracy != null)
                            Text(
                              'Reported accuracy: ±${accuracy.toStringAsFixed(0)} m',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          if ((row['note'] ?? '').toString().trim().isNotEmpty)
                            Text('Note: ${row['note']}'),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.tonalIcon(
                              onPressed: () => _openMap(row),
                              icon: const Icon(Icons.map_outlined),
                              label: const Text('Open location in Maps'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
