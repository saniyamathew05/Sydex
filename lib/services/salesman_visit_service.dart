import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SalesmanDailyActivity {
  const SalesmanDailyActivity({
    required this.salesmanId,
    required this.salesmanName,
    required this.routeLocations,
    required this.visitedCustomerCount,
    required this.refusedCustomerCount,
    required this.assignedCustomerIds,
    this.routeName,
  });

  final String salesmanId;
  final String salesmanName;
  final List<String> routeLocations;
  final int visitedCustomerCount;
  final int refusedCustomerCount;
  final Set<String> assignedCustomerIds;
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
        final routeCustomerIds = _orderedCustomerIdsFromValue(
          route['customer_ids'],
        );
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
      // A newly assigned route starts a fresh visit run for today. Remove
      // stale visit outcomes from an earlier run so the new route is not
      // shown as already visited.
      try {
        await _client
            .from('salesman_customer_daily_status')
            .delete()
            .eq('entered_by', userId)
            .eq('status_date', _todayKey());
      } catch (_) {
        // Keep route assignment usable if an older deployment does not allow
        // deleting daily status rows; the date-scoped read remains safe.
      }
      await _client.from('salesman_daily_route_selections').upsert({
        'salesman_id': userId,
        'route_date': _todayKey(),
        'locations': cleaned,
      }, onConflict: 'salesman_id,route_date');
    }
  }

  static Future<Map<String, String>> loadTodayStatuses() async {
    final userId = _requireUserId();
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));
    final rows = await _client
        .from('salesman_customer_daily_status')
        .select('customer_id, status')
        .eq('status_date', _todayKey())
        .eq('entered_by', userId);

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
          .eq('user_id', userId)
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
  static Future<Map<String, String>> loadTodayStatusesForOwner({
    required String companyId,
  }) async {
    final rows = await _client
        .from('salesman_customer_daily_status')
        .select('customer_id, status')
        .eq('company_id', companyId)
        .eq('status_date', _todayKey());
    final result = <String, String>{};
    for (final row in rows) {
      final customerId = row['customer_id']?.toString();
      final status = row['status']?.toString();
      if (customerId != null && status != null) result[customerId] = status;
    }
    return result;
  }

  /// Visit outcomes grouped by Marketing Executive. A customer may be
  /// assigned to more than one executive, so an outcome must never be shared
  /// between their individual Pending/Visited lists.
  static Future<Map<String, Map<String, String>>>
  loadTodayStatusesForOwnerBySalesman({required String companyId}) async {
    final rows = await _client
        .from('salesman_customer_daily_status')
        .select('entered_by, customer_id, status')
        .eq('company_id', companyId)
        .eq('status_date', _todayKey());
    final result = <String, Map<String, String>>{};
    for (final row in rows) {
      final salesmanId = row['entered_by']?.toString();
      final customerId = row['customer_id']?.toString();
      final status = row['status']?.toString();
      if (salesmanId != null && customerId != null && status != null) {
        result.putIfAbsent(salesmanId, () => <String, String>{})[customerId] =
            status;
      }
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
          .select('salesman_id, locations, customer_ids, route_date')
          .lte('route_date', today)
          .order('route_date', ascending: false),
      _client
          .from('salesman_customer_daily_status')
          .select('entered_by, customer_id, status')
          .eq('status_date', today),
      _client.from('salesman_route_templates').select('route_name, locations'),
    ]);

    final profiles = List<Map<String, dynamic>>.from(results[0] as List);
    final routeRows = List<Map<String, dynamic>>.from(results[1] as List);
    final statusRows = List<Map<String, dynamic>>.from(results[2] as List);
    final templates = List<Map<String, dynamic>>.from(results[3] as List);

    final routesBySalesman = <String, List<String>>{};
    final customersBySalesman = <String, Set<String>>{};
    for (final row in routeRows) {
      final salesmanId = row['salesman_id']?.toString();
      final locations = row['locations'];
      final customerIds = _orderedCustomerIdsFromValue(row['customer_ids']);
      if (salesmanId != null && !routesBySalesman.containsKey(salesmanId)) {
        routesBySalesman[salesmanId] = locations is List
            ? locations
                  .map((location) => location.toString().trim())
                  .where((location) => location.isNotEmpty)
                  .toList()
            : <String>[];
        customersBySalesman[salesmanId] = customerIds.toSet();
      }
    }

    final visitsBySalesman = <String, Set<String>>{};
    final refusedBySalesman = <String, Set<String>>{};
    for (final row in statusRows) {
      final salesmanId = row['entered_by']?.toString();
      final customerId = row['customer_id']?.toString();
      if (salesmanId != null && customerId != null) {
        visitsBySalesman
            .putIfAbsent(salesmanId, () => <String>{})
            .add(customerId);
        if (row['status']?.toString() == 'rejected') {
          refusedBySalesman
              .putIfAbsent(salesmanId, () => <String>{})
              .add(customerId);
        }
      }
    }

    return profiles.map((profile) {
      final salesmanId = profile['id'].toString();
      final locations = routesBySalesman[salesmanId] ?? const <String>[];
      final assignedIds = customersBySalesman[salesmanId] ?? const <String>{};
      final visitedIds = assignedIds.isEmpty
          ? (visitsBySalesman[salesmanId] ?? const <String>{})
          : (visitsBySalesman[salesmanId] ?? const <String>{}).intersection(
              assignedIds,
            );
      final refusedIds = assignedIds.isEmpty
          ? (refusedBySalesman[salesmanId] ?? const <String>{})
          : (refusedBySalesman[salesmanId] ?? const <String>{}).intersection(
              assignedIds,
            );
      final routeName = _findRouteName(templates, locations);

      return SalesmanDailyActivity(
        salesmanId: salesmanId,
        salesmanName: profile['name']?.toString() ?? 'Salesman',
        routeName: routeName,
        routeLocations: locations,
        visitedCustomerCount: visitedIds.length,
        refusedCustomerCount: refusedIds.length,
        assignedCustomerIds: assignedIds,
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

  /// Best-effort location capture for visits. A visit is still recorded if GPS
  /// is unavailable, but asking for permission here lets first-time users save
  /// the customer's position for the owner map.
  static Future<Position?> captureLocationForVisit() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // Recording a payment or visit must not depend on optional GPS capture.
      return null;
    }
  }

  static Future<bool> recordStatus({
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
    final position = capturedPosition ?? await captureLocationForVisit();
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
    return position != null;
  }
}
