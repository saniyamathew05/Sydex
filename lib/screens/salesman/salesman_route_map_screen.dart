import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/salesman_visit_service.dart';

class SalesmanRouteMapScreen extends StatefulWidget {
  const SalesmanRouteMapScreen({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<SalesmanRouteMapScreen> createState() => _SalesmanRouteMapScreenState();
}

class _SalesmanRouteMapScreenState extends State<SalesmanRouteMapScreen> {
  final _client = Supabase.instance.client;
  List<Map<String, dynamic>> _customers = const [];
  Set<String> _visited = <String>{};
  bool _loading = true;
  String? _error;
  LatLng? _currentLocation;
  String? _selectedCustomerId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _loadCurrentLocation();
      final ids = await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      if (ids.isEmpty) {
        if (mounted) setState(() { _customers = const []; _loading = false; });
        return;
      }
      final rows = await _client
          .from('customers')
          .select('id, business_name, location, latitude, longitude')
          .inFilter('id', ids);
      final byId = {for (final row in rows) row['id'].toString(): Map<String, dynamic>.from(row)};
      final ordered = ids.map((id) => byId[id]).whereType<Map<String, dynamic>>().where((row) {
        final lat = double.tryParse(row['latitude']?.toString() ?? '');
        final lon = double.tryParse(row['longitude']?.toString() ?? '');
        return lat != null && lon != null;
      }).toList();
      final statuses = await SalesmanVisitService.loadTodayStatuses();
      if (!mounted) return;
      setState(() {
        _customers = ordered;
        _visited = statuses.entries.where((entry) => entry.value == 'paid' || entry.value == 'rejected').map((entry) => entry.key).toSet();
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _loading = false; });
    }
  }

  Future<void> _loadCurrentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) return;
    final position = await Geolocator.getCurrentPosition();
    _currentLocation = LatLng(position.latitude, position.longitude);
  }

  Future<void> _navigateTo(Map<String, dynamic> customer) async {
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${customer['latitude']},${customer['longitude']}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final points = _customers.map((row) => LatLng(double.parse(row['latitude'].toString()), double.parse(row['longitude'].toString()))).toList();
    final hasMapLocation = _currentLocation != null || points.isNotEmpty;
    final center = _currentLocation ?? (points.isEmpty ? const LatLng(20.5937, 78.9629) : points.first);
    final pending = _customers.where((row) => !_visited.contains(row['id'].toString())).toList();
    final selectedMatches = _selectedCustomerId == null
        ? const <Map<String, dynamic>>[]
        : _customers.where((row) => row['id'].toString() == _selectedCustomerId).toList();
    final selected = selectedMatches.isEmpty ? null : selectedMatches.first;
    final next = selected ?? (pending.isEmpty ? null : pending.first);
    final routePoints = _currentLocation != null && next != null
        ? [_currentLocation!, LatLng(double.parse(next['latitude'].toString()), double.parse(next['longitude'].toString()))]
        : const <LatLng>[];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back)),
        title: const Text("Today's route map"),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Could not load route map.'))
          : Column(children: [
              if (next != null) ListTile(
                leading: const Icon(Icons.navigation_outlined),
                title: Text('Next: ${next['business_name']}'),
                subtitle: Text(next['location']?.toString() ?? ''),
                trailing: FilledButton(onPressed: () => _navigateTo(next), child: const Text('Navigate')),
              ),
              Expanded(child: hasMapLocation
                  ? FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  // Street-level delivery view, similar to food-delivery apps.
                  initialZoom: _currentLocation != null ? 16.5 : 15,
                ),
                children: [
                  TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.horizon.horizon'),
                  if (routePoints.isNotEmpty)
                    PolylineLayer(polylines: [Polyline(points: routePoints, strokeWidth: 5, color: Theme.of(context).colorScheme.primary)]),
                  MarkerLayer(markers: [
                    if (_currentLocation != null)
                      Marker(point: _currentLocation!, width: 46, height: 46, child: const Icon(Icons.my_location, color: Colors.blue, size: 30)),
                    ..._customers.map((row) => Marker(
                    point: LatLng(double.parse(row['latitude'].toString()), double.parse(row['longitude'].toString())),
                    width: 48, height: 56,
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedCustomerId = row['id'].toString()),
                      child: Icon(Icons.location_on, size: 44, color: row['id'].toString() == _selectedCustomerId ? Colors.orange : (_visited.contains(row['id'].toString()) ? Colors.blue : Colors.green.shade700)),
                    ),
                  )),
                  ]),
                  const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
                ],
              )
                  : const Center(
                      child: Text(
                        'Turn on location or visit a customer to see the delivery map.',
                        textAlign: TextAlign.center,
                      ),
                    )),
            ]),
    );
  }
}
