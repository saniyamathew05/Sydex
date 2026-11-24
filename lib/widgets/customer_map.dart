import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sydex_ui.dart';

/// A customer with a saved place on the map.
class CustomerStop {
  const CustomerStop({
    required this.id,
    required this.name,
    required this.place,
    required this.point,
    this.order,
    this.status = '',
  });

  final String id;
  final String name;
  final String place;
  final LatLng point;

  /// Position on the route, or null when the customer is not on it.
  final int? order;

  /// 'paid', 'rejected', or empty when not visited today.
  final String status;

  bool get visited => status == 'paid' || status == 'rejected';

  /// Reads a customers row, or null when it has no usable place.
  static CustomerStop? fromRow(
    Map<String, dynamic> row, {
    int? order,
    String status = '',
  }) {
    final lat = double.tryParse(row['latitude']?.toString() ?? '');
    final lng = double.tryParse(row['longitude']?.toString() ?? '');
    if (lat == null || lng == null) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return CustomerStop(
      id: row['id'].toString(),
      name: row['business_name']?.toString() ?? 'Customer',
      place: row['location']?.toString() ?? '',
      point: LatLng(lat, lng),
      order: order,
      status: status,
    );
  }
}

/// Every customer on a map with their name above the pin. Route stops are
/// numbered, with the way to the next stop drawn and its details below.
class CustomerMap extends StatefulWidget {
  const CustomerMap({
    super.key,
    required this.stops,
    this.currentLocation,
    this.onOpenCustomer,
    this.emptyMessage = 'No customer locations are saved yet.',
  });

  final List<CustomerStop> stops;
  final LatLng? currentLocation;
  final ValueChanged<CustomerStop>? onOpenCustomer;
  final String emptyMessage;

  @override
  State<CustomerMap> createState() => _CustomerMapState();
}

class _CustomerMapState extends State<CustomerMap> {
  static const _ink = Color(0xFF141414);
  static const _red = Color(0xFFDC2626);
  static const _grey = Color(0xFF6F6B64);

  final _map = MapController();
  String? _selectedId;
  Size _size = Size.zero;

  List<CustomerStop> get _route =>
      widget.stops.where((stop) => stop.order != null).toList()
        ..sort((a, b) => a.order!.compareTo(b.order!));

  CustomerStop? get _next {
    for (final stop in _route) {
      if (!stop.visited) return stop;
    }
    return null;
  }

  CustomerStop? get _selected {
    for (final stop in widget.stops) {
      if (stop.id == _selectedId) return stop;
    }
    return _next;
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void _select(CustomerStop stop) {
    setState(() => _selectedId = stop.id);
    _map.move(stop.point, math.max(_map.camera.zoom, 15));
  }

  CameraFit _fit(List<LatLng> points) => CameraFit.coordinates(
    coordinates: points,
    // Room for names and the panels, without swallowing a small map.
    padding: EdgeInsets.fromLTRB(
      math.min(90, _size.width * .2),
      math.min(110, _size.height * .28),
      math.min(90, _size.width * .2),
      math.min(130, _size.height * .28),
    ),
    maxZoom: 16,
  );

  List<LatLng> get _everything => [
    for (final stop in widget.stops) stop.point,
    ?widget.currentLocation,
  ];

  /// Opens on the way to the next stop, or on every customer.
  List<LatLng> get _firstView {
    final next = _next;
    final here = widget.currentLocation;
    if (next == null) return _everything;
    return [?here, if (here == null) ..._route.map((s) => s.point), next.point];
  }

  void _step(int by) {
    final route = _route.isEmpty ? widget.stops : _route;
    final at = route.indexWhere((stop) => stop.id == _selected?.id);
    _select(route[(at + by + route.length) % route.length]);
  }

  Future<void> _directions(CustomerStop stop) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination='
      '${stop.point.latitude},${stop.point.longitude}',
    );
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open Maps.')));
    }
  }

  Color _pinColor(CustomerStop stop) {
    if (stop.status == 'rejected') return _red;
    if (stop.id == _next?.id) return _ink;
    return stop.visited || stop.order == null ? _grey : _ink;
  }

  /// The way ahead: from here to the next stop, then through the stops left.
  List<Polyline> _lines() {
    final next = _next;
    if (next == null) return const [];
    final ahead = _route
        .where((stop) => !stop.visited)
        .map((stop) => stop.point)
        .toList();
    final here = widget.currentLocation;
    return [
      if (ahead.length > 1)
        Polyline(
          points: ahead,
          strokeWidth: 3,
          color: _ink.withValues(alpha: .45),
          pattern: StrokePattern.dashed(segments: const [10, 8]),
        ),
      if (here != null)
        Polyline(
          points: [here, next.point],
          strokeWidth: 5,
          color: _ink,
          borderStrokeWidth: 2,
          borderColor: Colors.white,
        ),
    ];
  }

  /// An arrow half-way along the first leg, pointing to the next stop.
  Marker? _arrow() {
    final next = _next;
    if (next == null) return null;
    final from = widget.currentLocation;
    if (from == null) return null;
    const distance = Distance();
    final metres = distance.as(LengthUnit.Meter, from, next.point);
    if (metres < 30) return null;
    final bearing = distance.bearing(from, next.point);
    return Marker(
      point: distance.offset(from, metres / 2, bearing),
      width: 34,
      height: 34,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: _ink, width: 2),
        ),
        child: Transform.rotate(
          angle: bearing * math.pi / 180,
          child: const Icon(Icons.navigation, size: 18, color: _ink),
        ),
      ),
    );
  }

  String? _distanceTo(CustomerStop stop) {
    final here = widget.currentLocation;
    if (here == null) return null;
    const distance = Distance();
    final metres = distance.as(LengthUnit.Meter, here, stop.point);
    const directions = [
      'north',
      'north-east',
      'east',
      'south-east',
      'south',
      'south-west',
      'west',
      'north-west',
    ];
    final bearing = (distance.bearing(here, stop.point) + 360) % 360;
    final way = directions[((bearing + 22.5) ~/ 45) % 8];
    return metres < 1000
        ? '${metres.round()} m $way'
        : '${(metres / 1000).toStringAsFixed(1)} km $way';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_everything.isEmpty) {
      return SydexCard(
        child: Center(
          child: Text(
            widget.emptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return _buildMap(colors);
      },
    );
  }

  Widget _buildMap(ColorScheme colors) {
    final selected = _selected;
    final arrow = _arrow();
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(initialCameraFit: _fit(_firstView)),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.horizon.horizon',
              ),
              PolylineLayer(polylines: _lines()),
              Builder(
                builder: (context) {
                  // With many customers, names appear as the map is zoomed in.
                  final names =
                      widget.stops.length <= 25 ||
                      MapCamera.of(context).zoom >= 13;
                  final ordered = [...widget.stops]
                    ..sort((a, b) {
                      int rank(CustomerStop s) =>
                          s.id == selected?.id ? 2 : (s.order == null ? 0 : 1);
                      return rank(a).compareTo(rank(b));
                    });
                  return MarkerLayer(
                    markers: [
                      for (final stop in ordered)
                        Marker(
                          point: stop.point,
                          width: 170,
                          height: 78,
                          alignment: Alignment.topCenter,
                          child: _Pin(
                            stop: stop,
                            color: _pinColor(stop),
                            selected: stop.id == selected?.id,
                            showName: names || stop.id == selected?.id,
                            onTap: () => _select(stop),
                          ),
                        ),
                      if (widget.currentLocation != null)
                        Marker(
                          point: widget.currentLocation!,
                          width: 26,
                          height: 26,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF2587F7),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                              boxShadow: const [
                                BoxShadow(color: Colors.black38, blurRadius: 5),
                              ],
                            ),
                          ),
                        ),
                      ?arrow,
                    ],
                  );
                },
              ),
              const RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          if (_size.height >= 260)
          Positioned(
            left: 10,
            top: 10,
            child: _Panel(
              child: Wrap(
                direction: Axis.vertical,
                spacing: 4,
                children: [
                  if (_route.isNotEmpty)
                    const _MapKey(color: _ink, label: 'To visit'),
                  _MapKey(
                    color: _grey,
                    label: _route.isEmpty ? 'Customer' : 'Visited / other',
                  ),
                  if (widget.stops.any((s) => s.status == 'rejected'))
                    const _MapKey(color: _red, label: 'Refused'),
                ],
              ),
            ),
          ),
          Positioned(
            right: 10,
            top: 10,
            child: Column(
              children: [
                SydexIconButton(
                  icon: Icons.zoom_out_map_rounded,
                  tooltip: 'Show all customers',
                  onPressed: () => _map.fitCamera(_fit(_everything)),
                ),
                if (widget.currentLocation != null) ...[
                  const SizedBox(height: 8),
                  SydexIconButton(
                    icon: Icons.my_location_rounded,
                    tooltip: 'Show where I am',
                    onPressed: () => _map.move(widget.currentLocation!, 16),
                  ),
                ],
              ],
            ),
          ),
          if (selected != null)
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: _Panel(
                    padding: const EdgeInsets.all(12),
                    child: _stopCard(selected, colors),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stopCard(CustomerStop stop, ColorScheme colors) {
    final isNext = stop.id == _next?.id;
    final details = [
      if (stop.place.isNotEmpty) stop.place,
      ?_distanceTo(stop),
    ].join(' · ');
    final status = switch (stop.status) {
      'paid' => 'Visited today',
      'rejected' => 'Refused today',
      _ when isNext => 'Next stop',
      _ when stop.order != null => 'Stop ${stop.order}',
      _ => 'Customer',
    };
    return Row(
      children: [
        if (_route.length > 1)
          IconButton(
            tooltip: 'Previous stop',
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
        Expanded(
          child: InkWell(
            onTap: widget.onOpenCustomer == null
                ? null
                : () => widget.onOpenCustomer!(stop),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: stop.status == 'rejected'
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  stop.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () => _directions(stop),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          child: const Text('Directions'),
        ),
        if (_route.length > 1)
          IconButton(
            tooltip: 'Next stop',
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
      ],
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({
    required this.stop,
    required this.color,
    required this.selected,
    required this.showName,
    required this.onTap,
  });

  final CustomerStop stop;
  final Color color;
  final bool selected;
  final bool showName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      if (showName)
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              // Map tiles are always light, so these colours do not follow
              // the dark theme.
              color: selected ? color : Colors.white,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: color),
            ),
            child: Text(
              stop.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF141414),
              ),
            ),
          ),
        ),
      GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Icon(
                Icons.location_on,
                size: 44,
                color: color,
                shadows: const [Shadow(color: Colors.white, blurRadius: 4)],
              ),
              Positioned(
                top: 8,
                child: Container(
                  width: 19,
                  height: 19,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: stop.status == 'paid'
                      ? Icon(Icons.check_rounded, size: 14, color: color)
                      : stop.status == 'rejected'
                      ? Icon(Icons.close_rounded, size: 14, color: color)
                      : stop.order != null
                      ? Text(
                          '${stop.order}',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        )
                      : Icon(Icons.storefront_rounded, size: 13, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _MapKey extends StatelessWidget {
  const _MapKey({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}
