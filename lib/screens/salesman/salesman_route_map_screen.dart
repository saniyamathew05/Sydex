import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/salesman_visit_service.dart';
import '../../widgets/customer_map.dart';
import '../../widgets/sydex_ui.dart';

/// Every customer with a saved place, with today's route numbered in order.
class SalesmanRouteMapScreen extends StatefulWidget {
  const SalesmanRouteMapScreen({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<SalesmanRouteMapScreen> createState() => _SalesmanRouteMapScreenState();
}

class _SalesmanRouteMapScreenState extends State<SalesmanRouteMapScreen> {
  List<CustomerStop> _stops = const [];
  int _unplaced = 0;
  bool _loading = true;
  String? _error;
  LatLng? _currentLocation;
  int _version = 0;

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
      await _loadCurrentLocation();
      final ids = await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      final statuses = await SalesmanVisitService.loadTodayStatuses();
      final rows = List<Map<String, dynamic>>.from(
        await Supabase.instance.client
            .from('customers')
            .select('id, business_name, location, latitude, longitude')
            .eq('is_active', true)
            .limit(2000),
      );
      final stops = <CustomerStop>[];
      for (final row in rows) {
        final id = row['id'].toString();
        final at = ids.indexOf(id);
        final stop = CustomerStop.fromRow(
          row,
          order: at < 0 ? null : at + 1,
          status: statuses[id] ?? '',
        );
        if (stop != null) stops.add(stop);
      }
      if (!mounted) return;
      final placed = {for (final stop in stops) stop.id};
      setState(() {
        _stops = stops;
        _unplaced = ids.where((id) => !placed.contains(id)).length;
        _version++;
        _loading = false;
      });
    } catch (error) {
      debugPrint('Could not load the route map: $error');
      if (mounted) {
        setState(() {
          _error = 'Could not load the route map.';
          _loading = false;
        });
      }
    }
  }

  /// The map works without a position, so a problem here is never fatal.
  Future<void> _loadCurrentLocation() async {
    try {
      final position = await SalesmanVisitService.captureLocationForVisit();
      if (position != null) {
        _currentLocation = LatLng(position.latitude, position.longitude);
      }
    } on Exception catch (error) {
      debugPrint('Could not read the current location: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          child: SydexScreenHeader(
            eyebrow: 'Today’s stops and customers',
            title: 'Route map',
            actions: [
              SydexIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Refresh',
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
        ),
        if (_unplaced > 0 && !_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '$_unplaced customer${_unplaced == 1 ? '' : 's'} on your route will appear after the first visit with location on.',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  )
                : CustomerMap(
                    key: ValueKey(_version),
                    stops: _stops,
                    currentLocation: _currentLocation,
                    emptyMessage:
                        'Turn on location or visit a customer to see the map.',
                  ),
          ),
        ),
      ],
    );
  }
}
