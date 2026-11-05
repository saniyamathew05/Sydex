import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SalesmanDailyActivity {
  const SalesmanDailyActivity({
    required this.salesmanId,
    required this.salesmanName,
    required this.routeLocations,
    required this.visitedCustomerCount,
    this.routeName,
  });

  final String salesmanId;
  final String salesmanName;
  final List<String> routeLocations;
  final int visitedCustomerCount;
  final String? routeName;
}

/// Supabase-backed route selection and daily customer visit status service.
class SalesmanVisitService {
  SalesmanVisitService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static String _todayKey() {
    final now = DateTime.now();
    final year = now.year.toString().padLeft(4, '0');
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  static String _requireUserId() {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('You must be signed in to record a route or visit.');
    }
    return userId;
  }

  static Future<List<String>> loadTodayRoute() async {
    final userId = _requireUserId();
    final row = await _client
        .from('salesman_daily_route_selections')
        .select('locations, route_date')
        .eq('salesman_id', userId)
        .lte('route_date', _todayKey())
        .order('route_date', ascending: false)
        .limit(1)
        .maybeSingle();

    if (row == null) return <String>[];
    final value = row['locations'];
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
    return <String>[];
  }

  /// Loads the assigned customer IDs in the exact order saved by the owner.
  static Future<List<String>> loadTodayCustomerIdsInOrder() async {
    final userId = _requireUserId();
    try {
      final row = await _client
          .from('salesman_daily_route_selections')
          .select('customer_ids, locations')
          .eq('salesman_id', userId)
          .lte('route_date', _todayKey())
          .order('route_date', ascending: false)
          .limit(1)
          .maybeSingle();

      final assignedIds = _orderedCustomerIdsFromValue(row?['customer_ids']);
      if (assignedIds.isNotEmpty) return assignedIds;

      // Customer IDs are the authoritative assignment. Empty means no customers assigned.
    } catch (_) {
      // The customer_ids column is optional for older deployed databases.
    }
    return <String>[];
  }

  /// Membership-only compatibility API for screens that do not display order.
  static Future<Set<String>> loadTodayCustomerIds() async =>
      (await loadTodayCustomerIdsInOrder()).toSet();

  static List<String> _orderedCustomerIdsFromValue(dynamic value) {
    List<dynamic>? values;
    if (value is List) values = value;
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) values = decoded;
      } catch (_) {}
    }
    if (values == null) return <String>[];

    final seen = <String>{};
    return values
        .map((item) => item.toString().trim())
        .where((id) => id.isNotEmpty && seen.add(id))
        .toList(growable: false);
  }

  static Set<String> _normalizedLocations(dynamic value) {
    if (value is! List) return <String>{};
    return value
        .map((location) => location.toString().trim().toLowerCase())
        .where((location) => location.isNotEmpty)
        .toSet();
  }

  static Future<String?> loadRouteNameForLocations(
    List<String> assignedLocations,
  ) async {
    final routes = await _client
        .from('salesman_route_templates')
        .select('route_name, locations');
    return _findRouteName(
      List<Map<String, dynamic>>.from(routes),
      assignedLocations,
    );
  }

  /// Resolve the named route using its originally assigned customers. This
  /// keeps the name stable when the owner later adds extra customers to a
  /// salesman's daily route.
  static Future<String?> loadRouteNameForCustomerIds(
    List<String> assignedCustomerIds, {
    List<String> assignedLocations = const <String>[],
  }) async {
    final assigned = assignedCustomerIds.toSet();
    if (assigned.isNotEmpty) {
      final routes = await _client
          .from('salesman_route_templates')
          .select('route_name, locations, customer_ids');
      final matches = <({String name, int customerCount})>[];
      for (final route in routes) {
        final name = route['route_name']?.toString().trim() ?? '';
        final routeCustomerIds =
            _orderedCustomerIdsFromValue(route['customer_ids']);
        if (name.isEmpty ||
            routeCustomerIds.isEmpty ||
            !routeCustomerIds.every(assigned.contains)) {
          continue;
        }
        matches.add((name: name, customerCount: routeCustomerIds.length));
      }
      if (matches.isNotEmpty) {
        matches.sort((a, b) {
          final bySpecificity = b.customerCount.compareTo(a.customerCount);
          return bySpecificity != 0 ? bySpecificity : a.name.compareTo(b.name);
        });
        return matches.first.name;
      }
    }
    return loadRouteNameForLocations(assignedLocations);
  }

  static String? _findRouteName(
    List<Map<String, dynamic>> routes,
    List<String> assignedLocations,
  ) {
    final assigned = assignedLocations
        .map((location) => location.trim().toLowerCase())
        .where((location) => location.isNotEmpty)
        .toSet();
    if (assigned.isEmpty) return null;

    final matches = <({String name, int extraLocations})>[];
    for (final route in routes) {
      final rawLocations = route['locations'];
      if (rawLocations is! List) continue;
      final routeLocations = rawLocations
          .map((location) => location.toString().trim().toLowerCase())
          .where((location) => location.isNotEmpty)
          .toSet();
      if (!assigned.every(routeLocations.contains)) continue;

      final name = route['route_name']?.toString().trim();
      if (name == null || name.isEmpty) continue;
      matches.add((
        name: name,
        extraLocations: routeLocations.length - assigned.length,
      ));
    }

    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final bySpecificity = a.extraLocations.compareTo(b.extraLocations);
      return bySpecificity != 0 ? bySpecificity : a.name.compareTo(b.name);
    });
    return matches.first.name;
  }

  static Future<void> saveTodayRoute(List<String> locations) async {
    final userId = _requireUserId();
    final cleaned =
        locations
            .map((location) => location.trim())
            .where((location) => location.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (cleaned.isNotEmpty) {
      await _client.from('salesman_daily_route_selections').upsert({
        'salesman_id': userId,
        'route_date': _todayKey(),
        'locations': cleaned,
      }, onConflict: 'salesman_id,route_date');
    }
  }

  static Future<Map<String, String>> loadTodayStatuses() async {
    _requireUserId();
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));
    final rows = await _client
        .from('salesman_customer_daily_status')
        .select('customer_id, status')
        .eq('status_date', _todayKey());

    final result = <String, String>{};
    for (final row in rows) {
      final customerId = row['customer_id']?.toString();
      final status = row['status']?.toString();
      if (customerId != null && status != null) {
        result.putIfAbsent(customerId, () => status);
      }
    }

    // Payments saved before visit-status recording was fixed (or recorded by
    // the owner/another salesman) still count as a completed visit today.
    try {
      final payments = await _client
          .from('payments')
          .select('customer_id')
          .gte('transaction_date', startOfToday.toUtc().toIso8601String())
          .lt('transaction_date', startOfTomorrow.toUtc().toIso8601String());
      for (final payment in payments) {
        final customerId = payment['customer_id']?.toString();
        // An explicit visit outcome is the source of truth for today. Payment
        // history is only a fallback for older records that predate visit
        // status tracking; it must not turn an explicit refusal into "paid".
        if (customerId != null) result.putIfAbsent(customerId, () => 'paid');
      }
    } catch (_) {
      // Keep visit statuses usable if payment history is temporarily restricted.
    }

    return result;
  }

  /// Owner view remains limited to statuses recorded today.
  static Future<Map<String, String>> loadTodayStatusesForOwner() async {
    final rows = await _client
        .from('salesman_customer_daily_status')
        .select('customer_id, status')
        .eq('status_date', _todayKey());
    final result = <String, String>{};
    for (final row in rows) {
      final customerId = row['customer_id']?.toString();
      final status = row['status']?.toString();
      if (customerId != null && status != null) result[customerId] = status;
    }
    return result;
  }

  static Future<List<SalesmanDailyActivity>> loadTodaySalesmanActivity() async {
    final today = _todayKey();
    final results = await Future.wait([
      _client
          .from('profiles')
          .select('id, name')
          .eq('role', 'salesman')
          .order('name'),
      _client
          .from('salesman_daily_route_selections')
          .select('salesman_id, locations, route_date')
          .lte('route_date', today)
          .order('route_date', ascending: false),
      _client
          .from('salesman_customer_daily_status')
          .select('entered_by, customer_id')
          .eq('status_date', today),
      _client.from('salesman_route_templates').select('route_name, locations'),
    ]);

    final profiles = List<Map<String, dynamic>>.from(results[0] as List);
    final routeRows = List<Map<String, dynamic>>.from(results[1] as List);
    final statusRows = List<Map<String, dynamic>>.from(results[2] as List);
    final templates = List<Map<String, dynamic>>.from(results[3] as List);

    final routesBySalesman = <String, List<String>>{};
    for (final row in routeRows) {
      final salesmanId = row['salesman_id']?.toString();
      final locations = row['locations'];
      if (salesmanId != null &&
          locations is List &&
          !routesBySalesman.containsKey(salesmanId)) {
        routesBySalesman[salesmanId] = locations
            .map((location) => location.toString().trim())
            .where((location) => location.isNotEmpty)
            .toList();
      }
    }

    final visitsBySalesman = <String, Set<String>>{};
    for (final row in statusRows) {
      final salesmanId = row['entered_by']?.toString();
      final customerId = row['customer_id']?.toString();
      if (salesmanId != null && customerId != null) {
        visitsBySalesman
            .putIfAbsent(salesmanId, () => <String>{})
            .add(customerId);
      }
    }

    return profiles.map((profile) {
      final salesmanId = profile['id'].toString();
      final locations = routesBySalesman[salesmanId] ?? const <String>[];
      final routeName = _findRouteName(templates, locations);

      return SalesmanDailyActivity(
        salesmanId: salesmanId,
        salesmanName: profile['name']?.toString() ?? 'Salesman',
        routeName: routeName,
        routeLocations: locations,
        visitedCustomerCount: visitsBySalesman[salesmanId]?.length ?? 0,
      );
    }).toList();
  }

  static Future<Position> captureLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw StateError('Turn on location services and try again.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw StateError('Location permission was denied.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission is permanently denied. Enable it in system settings.',
      );
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
  }

  /// Returns a location only when permission is already granted and GPS is on.
  /// This never asks the salesman to enable location services.
  static Future<Position?> captureLocationIfAlreadyAllowed() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 3),
        ),
      );
    } catch (_) {
      // Payment completion must not depend on optional visit location capture.
      return null;
    }
  }

  static Future<void> recordStatus({
    required String customerId,
    required String status,
    Position? capturedPosition,
    String? note,
  }) async {
    if (status != 'paid' && status != 'rejected') {
      throw ArgumentError.value(status, 'status', 'Expected paid or rejected.');
    }

    // GPS is optional for either outcome. Preserve an already captured
    // position for the visit audit, but never block recording the visit on it.
    final position =
        capturedPosition ?? await captureLocationIfAlreadyAllowed();
    await _client.rpc(
      'record_salesman_customer_status',
      params: {
        'p_customer_id': customerId,
        'p_status': status,
        'p_latitude': position?.latitude,
        'p_longitude': position?.longitude,
        'p_accuracy_meters': position?.accuracy,
        'p_note': note,
      },
    );
  }
}
