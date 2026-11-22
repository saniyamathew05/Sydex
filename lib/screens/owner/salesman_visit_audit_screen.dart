import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../widgets/sydex_ui.dart';

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
    final Widget content = _loading
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
                  FilledButton(onPressed: _load, child: const Text('Try again')),
                ],
              ),
            ),
          )
        : _visits.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_searching, size: 42, color: colors.outline),
                  const SizedBox(height: 12),
                  const Text(
                    'No visit records yet',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'When a salesman records a payment or refusal, the captured location will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                SydexCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      for (var index = 0; index < _visits.length; index++) ...[
                        if (index > 0)
                          Divider(height: 1, color: colors.outlineVariant),
                        _visitRow(_visits[index], colors),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: SydexScreenHeader(
                eyebrow: 'Verify salesman locations',
                title: 'Visit audit',
                leading: Navigator.of(context).canPop()
                    ? SydexIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    : null,
                actions: [
                  SydexIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Refresh',
                    onPressed: _load,
                  ),
                ],
              ),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  Widget _visitRow(Map<String, dynamic> row, ColorScheme colors) {
    final customer = Map<String, dynamic>.from(row['customer'] as Map);
    final salesman = Map<String, dynamic>.from(row['salesman'] as Map);
    final rejected = row['status'] == 'rejected';
    final timestamp = DateTime.tryParse(
      row['captured_at']?.toString() ?? '',
    )?.toLocal();
    final accuracy = (row['accuracy_meters'] as num?)?.toDouble();
    final time = timestamp == null
        ? 'Time unavailable'
        : '${timestamp.day.toString().padLeft(2, '0')}/${timestamp.month.toString().padLeft(2, '0')}/${timestamp.year}  ${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.location_on_outlined, size: 19, color: colors.onSurface),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        customer['business_name']?.toString() ?? 'Unknown customer',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SydexBadge(
                      rejected ? 'No payment' : 'Payment recorded',
                      tone: rejected ? SydexTone.negative : SydexTone.positive,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if ((customer['location'] ?? '').toString().isNotEmpty)
                      customer['location'].toString(),
                    '${salesman['name'] ?? 'Salesman'}',
                    time,
                  ].join(' · '),
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  'GPS ${(row['latitude'] as num).toStringAsFixed(6)}, ${(row['longitude'] as num).toStringAsFixed(6)}${accuracy == null ? '' : ' · ±${accuracy.toStringAsFixed(0)} m'}',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                ),
                if ((row['note'] ?? '').toString().trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Note: ${row['note']}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                TextButton(
                  onPressed: () => _openMap(row),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(44, 34),
                    alignment: Alignment.centerLeft,
                  ),
                  child: const Text('Open location in Maps'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
