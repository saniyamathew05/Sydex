import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:file_selector/file_selector.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/customer.dart';
import '../../services/currency_formatter.dart';
import '../../services/customer_service.dart';
import '../../services/salesman_visit_service.dart';
import '../../services/transaction_service.dart';
import '../customers/customer_details_screen.dart';
import '../../widgets/customer_map.dart';
import '../../widgets/root_back_guard.dart';
import '../../widgets/sydex_ui.dart';

/// Owner tools for reusable named routes and per-day location assignments.
/// Requires the SQL migration in owner_route_management_schema.sql.
enum OwnerRoutePage { places, salesmen, map }

class OwnerRouteManagementScreen extends StatefulWidget {
  final OwnerRoutePage page;
  const OwnerRouteManagementScreen({
    super.key,
    this.page = OwnerRoutePage.places,
  });

  @override
  State<OwnerRouteManagementScreen> createState() =>
      _OwnerRouteManagementScreenState();
}

class _OwnerRouteManagementScreenState
    extends State<OwnerRouteManagementScreen> {
  final _client = Supabase.instance.client;
  final _routeNameController = TextEditingController();
  RealtimeChannel? _visitStatusChannel;
  bool _refreshingVisitStatuses = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _companyId;
  List<Map<String, dynamic>> _routes = [];
  List<Map<String, dynamic>> _salesmen = [];
  final Map<String, List<String>> _todayAssignments = {};
  final Map<String, List<String>> _todayCustomerAssignments = {};
  final Map<String, List<String>> _queuedCustomerAssignments = {};
  Map<String, Map<String, String>> _todayCustomerStatusesBySalesman = {};
  final Map<String, String> _customerFiltersBySalesman = {};
  final Map<String, String> _customerSearchBySalesman = {};
  String _salesmanFilterId = '';
  String? _selectedRouteId;
  final Set<String> _selectedSalesmanIds = {};
  Set<String> _selectedCustomerIds = {};
  List<Map<String, dynamic>> _mapVisits = [];
  int _mapCustomerCount = 0;
  String _mapSalesmanId = '';
  bool _mapVisitsLoading = false;
  bool _mapVisitsRefreshPending = false;

  Map<String, dynamic>? get _selectedRoute {
    for (final route in _routes) {
      if (route['id'].toString() == _selectedRouteId) return route;
    }
    return null;
  }

  Set<String> _decodeCustomerIds(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((entry) => entry.toString()).toSet();
      }
    } catch (_) {
      // Legacy rows may contain a malformed serialized value; treat them as
      // having no explicit customer selection rather than showing a wrong
      // count or crashing the route screen.
    }
    return <String>{};
  }

  int get _selectedCustomerCount {
    final knownIds = CustomerService.customers
        .map((customer) => customer.id)
        .toSet();
    return _selectedCustomerIds.where(knownIds.contains).length;
  }

  List<String> _locationsForSelectedCustomers() {
    final byId = {
      for (final customer in CustomerService.customers) customer.id: customer,
    };
    final locations = <String>[];
    final seen = <String>{};
    for (final id in _selectedCustomerIds) {
      final location = byId[id]?.location.trim() ?? '';
      if (location.isNotEmpty && seen.add(location.toLowerCase())) {
        locations.add(location);
      }
    }
    return locations;
  }

  List<String> _otherSalesmenAssignedToCustomer(
    String customerId, {
    String excludingSalesmanId = '',
  }) {
    return _salesmen
        .where((salesman) {
          final salesmanId = (salesman['id'] ?? '').toString();
          return salesmanId.isNotEmpty &&
              salesmanId != excludingSalesmanId &&
              (_todayCustomerAssignments[salesmanId] ?? const <String>[])
                  .contains(customerId);
        })
        .map((salesman) => (salesman['name'] ?? 'Salesman').toString())
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.page == OwnerRoutePage.map) {
      Future.microtask(_loadMapVisits);
    }
  }

  @override
  void dispose() {
    final visitStatusChannel = _visitStatusChannel;
    if (visitStatusChannel != null) {
      unawaited(_client.removeChannel(visitStatusChannel));
    }
    _routeNameController.dispose();
    super.dispose();
  }

  void _subscribeToVisitStatuses(String companyId) {
    if (widget.page != OwnerRoutePage.salesmen &&
        widget.page != OwnerRoutePage.map) {
      return;
    }
    if (_visitStatusChannel != null && _companyId == companyId) return;

    final previousChannel = _visitStatusChannel;
    _visitStatusChannel = null;
    if (previousChannel != null) {
      unawaited(_client.removeChannel(previousChannel));
    }

    _visitStatusChannel = _client
        .channel('owner-visit-statuses-$companyId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'salesman_customer_daily_status',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'company_id',
            value: companyId,
          ),
          callback: (_) {
            if (widget.page == OwnerRoutePage.map) {
              unawaited(_loadMapVisits());
            } else {
              unawaited(_refreshVisitStatuses());
            }
          },
        )
        .subscribe();
  }

  Future<void> _refreshVisitStatuses() async {
    if (_refreshingVisitStatuses) return;
    _refreshingVisitStatuses = true;
    try {
      final companyId = _companyId;
      if (companyId == null) return;
      final statuses =
          await SalesmanVisitService.loadTodayStatusesForOwnerBySalesman(
            companyId: companyId,
          );
      if (mounted) {
        setState(() => _todayCustomerStatusesBySalesman = statuses);
      }
    } catch (error) {
      debugPrint('Could not refresh owner visit statuses: $error');
    } finally {
      _refreshingVisitStatuses = false;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await CustomerService.loadCustomers();
      await TransactionService.loadCustomerBalances();
      final companyId = await _requireCompanyId();
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      List<Map<String, dynamic>> routeRows;
      try {
        final rows = await _client
            .from('salesman_route_templates')
            .select(
              'id, route_name, locations, customer_ids, updated_at, company_id',
            )
            .eq('company_id', companyId)
            .order('route_name');
        routeRows = List<Map<String, dynamic>>.from(rows);
      } catch (error) {
        // Keep existing routes usable until the optional customer_ids migration
        // has been applied in Supabase.
        debugPrint('Customer-level route column unavailable: $error');
        final rows = await _client
            .from('salesman_route_templates')
            .select('id, route_name, locations, updated_at, company_id')
            .eq('company_id', companyId)
            .order('route_name');
        routeRows = List<Map<String, dynamic>>.from(rows);
      }
      final results = await Future.wait<dynamic>([
        Future.value(routeRows),
        _client.from('profiles').select('id, name, role').order('name'),
        _client
            .from('salesman_daily_route_selections')
            .select(
              'salesman_id, locations, customer_ids, route_date, company_id',
            )
            .eq('company_id', companyId)
            .lte('route_date', todayKey)
            .order('route_date', ascending: false),
        _client
            .from('salesman_route_queue')
            .select('salesman_id, customer_ids, created_at, company_id')
            .eq('company_id', companyId)
            .order('created_at'),
        SalesmanVisitService.loadTodayStatusesForOwnerBySalesman(
          companyId: companyId,
        ),
      ]);
      final allProfiles = List<Map<String, dynamic>>.from(results[1] as List);
      final assignmentRows = List<Map<String, dynamic>>.from(
        results[2] as List,
      );
      final queuedRows = List<Map<String, dynamic>>.from(results[3] as List);
      final todayStatuses = Map<String, Map<String, String>>.from(
        results[4] as Map<String, Map<String, String>>,
      );
      final queuedAssignments = <String, List<String>>{};
      for (final row in queuedRows) {
        final id = (row['salesman_id'] ?? '').toString();
        final raw = row['customer_ids'];
        final ids = raw is List
            ? raw.map((e) => e.toString()).toList()
            : raw is String
            ? _decodeCustomerIds(raw).toList()
            : const <String>[];
        if (id.isNotEmpty) {
          queuedAssignments.putIfAbsent(id, () => <String>[]).addAll(ids);
        }
      }
      final assignments = <String, List<String>>{};
      final customerAssignments = <String, List<String>>{};
      for (final row in assignmentRows) {
        final id = (row['salesman_id'] ?? '').toString();
        final rawLocations = row['locations'];
        if (id.isNotEmpty && !assignments.containsKey(id)) {
          // The latest dated row is the active assignment. Empty rows are
          // owner-created removal markers that keep older routes inactive.
          if (rawLocations is List) {
            assignments[id] = rawLocations.map((e) => e.toString()).toList();
          } else {
            assignments[id] = <String>[];
          }
        }
        final rawCustomerIds = row['customer_ids'];
        List<String> parsedCustomerIds = const <String>[];
        if (rawCustomerIds is List) {
          parsedCustomerIds = rawCustomerIds.map((e) => e.toString()).toList();
        } else if (rawCustomerIds is String &&
            rawCustomerIds.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(rawCustomerIds);
            if (decoded is List) {
              parsedCustomerIds = decoded.map((e) => e.toString()).toList();
            }
          } catch (_) {
            // Keep the location assignment fallback for malformed legacy data.
          }
        }
        if (id.isNotEmpty && !customerAssignments.containsKey(id)) {
          customerAssignments[id] = parsedCustomerIds;
        }
      }
      final salesmen = allProfiles
          .where(
            (p) => (p['role'] ?? '').toString().toLowerCase() == 'salesman',
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _companyId = companyId;
        _routes = List<Map<String, dynamic>>.from(results[0] as List);
        _salesmen = salesmen;
        _todayAssignments
          ..clear()
          ..addAll(assignments);
        _todayCustomerAssignments
          ..clear()
          ..addAll(customerAssignments);
        _queuedCustomerAssignments
          ..clear()
          ..addAll(queuedAssignments);
        _todayCustomerStatusesBySalesman = todayStatuses;
        _selectedRouteId ??= _routes.isEmpty
            ? null
            : _routes.first['id'].toString();
        final availableSalesmanIds = _salesmen
            .map((salesman) => salesman['id'].toString())
            .toSet();
        if (!availableSalesmanIds.contains(_salesmanFilterId)) {
          _salesmanFilterId = '';
        }
        _selectedSalesmanIds.removeWhere(
          (id) => !availableSalesmanIds.contains(id),
        );
        final rawCustomerIds = _selectedRoute?['customer_ids'];
        final parsedCustomerIds = rawCustomerIds is List
            ? rawCustomerIds.map((e) => e.toString()).toSet()
            : rawCustomerIds is String && rawCustomerIds.trim().isNotEmpty
            ? _decodeCustomerIds(rawCustomerIds)
            : <String>{};
        _selectedCustomerIds = parsedCustomerIds;
        _loading = false;
      });
      _subscribeToVisitStatuses(companyId);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Could not load routes. Check your connection and route setup.';
      });
      debugPrint('Owner route management load failed: $error');
    }
  }

  Future<String> _requireCompanyId() async {
    final cached = _companyId;
    if (cached != null && cached.isNotEmpty) return cached;
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Please sign in again.');
    final profile = await _client
        .from('profiles')
        .select('company_id')
        .eq('id', userId)
        .maybeSingle();
    final companyId = profile?['company_id']?.toString();
    if (companyId == null || companyId.isEmpty) {
      throw StateError('This owner account is not linked to a company.');
    }
    _companyId = companyId;
    return companyId;
  }

  Future<void> _loadMapVisits() async {
    if (!mounted) return;
    if (_mapVisitsLoading) {
      _mapVisitsRefreshPending = true;
      return;
    }
    setState(() => _mapVisitsLoading = true);
    try {
      final userId = _client.auth.currentUser?.id;
      if (userId == null) throw StateError('Please sign in again.');
      final profile = await _client
          .from('profiles')
          .select('company_id')
          .eq('id', userId)
          .maybeSingle();
      final companyId = profile?['company_id']?.toString();
      if (companyId == null || companyId.isEmpty) {
        throw StateError('This account is not linked to a company.');
      }

      final customers = List<Map<String, dynamic>>.from(
        await _client
            .from('customers')
            .select('id, business_name, location, latitude, longitude')
            .eq('company_id', companyId)
            .eq('is_active', true)
            .order('business_name')
            .limit(2000),
      );
      final customerIds = customers
          .map((row) => row['id']?.toString())
          .whereType<String>()
          .toList();
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final statuses = customerIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await _client
                  .from('salesman_customer_daily_status')
                  .select('customer_id, status')
                  .eq('status_date', todayKey)
                  .inFilter('customer_id', customerIds),
            );
      final statusByCustomer = {
        for (final row in statuses)
          row['customer_id'].toString(): row['status']?.toString() ?? '',
      };
      final recorded = await _loadRecordedPlaces(
        customers
            .where((row) => row['latitude'] == null)
            .map((row) => row['id'].toString())
            .toSet(),
      );
      final points = <Map<String, dynamic>>[];
      for (final row in customers) {
        final customer = {...row, ...?recorded[row['id'].toString()]};
        final lat = double.tryParse(customer['latitude']?.toString() ?? '');
        final lng = double.tryParse(customer['longitude']?.toString() ?? '');
        if (lat == null ||
            lng == null ||
            lat < -90 ||
            lat > 90 ||
            lng < -180 ||
            lng > 180) {
          continue;
        }
        points.add({
          ...customer,
          'latitude': lat,
          'longitude': lng,
          'status': statusByCustomer[customer['id'].toString()] ?? '',
        });
      }
      if (!mounted) return;
      setState(() {
        _mapVisits = points;
        _mapCustomerCount = customers.length;
      });
    } catch (error) {
      debugPrint('Load visit map points failed: $error');
    } finally {
      if (mounted) {
        setState(() => _mapVisitsLoading = false);
        if (_mapVisitsRefreshPending) {
          _mapVisitsRefreshPending = false;
          unawaited(_loadMapVisits());
        }
      }
    }
  }

  /// Places recorded with earlier payments and refusals, for customers whose
  /// own record has no place yet.
  Future<Map<String, Map<String, dynamic>>> _loadRecordedPlaces(
    Set<String> customerIds,
  ) async {
    if (customerIds.isEmpty) return const {};
    try {
      final audits = List<Map<String, dynamic>>.from(
        await _client
            .from('salesman_visit_audit')
            .select('status_id, latitude, longitude')
            .order('captured_at', ascending: false)
            .limit(500),
      );
      if (audits.isEmpty) return const {};
      final statuses = List<Map<String, dynamic>>.from(
        await _client
            .from('salesman_customer_daily_status')
            .select('id, customer_id')
            .inFilter('id', [
              for (final audit in audits) audit['status_id'].toString(),
            ]),
      );
      final customerByStatus = {
        for (final row in statuses)
          row['id'].toString(): row['customer_id'].toString(),
      };
      final places = <String, Map<String, dynamic>>{};
      for (final audit in audits) {
        final customerId = customerByStatus[audit['status_id'].toString()];
        if (customerId == null || !customerIds.contains(customerId)) continue;
        places.putIfAbsent(
          customerId,
          () => {
            'latitude': audit['latitude'],
            'longitude': audit['longitude'],
          },
        );
      }
      return places;
    } catch (error) {
      debugPrint('Could not load recorded visit places: $error');
      return const {};
    }
  }

  Future<void> _createRoute() async {
    final name = _routeNameController.text.trim();
    if (name.isEmpty) {
      _message('Enter a route name first.');
      return;
    }
    setState(() => _saving = true);
    try {
      final companyId = await _requireCompanyId();
      final row = await _client
          .from('salesman_route_templates')
          .insert({
            'company_id': companyId,
            'route_name': name,
            'locations': _locationsForSelectedCustomers(),
            'customer_ids': _selectedCustomerIds.toList(),
          })
          .select('id, route_name, locations, customer_ids, updated_at, company_id')
          .single();
      if (!mounted) return;
      setState(() {
        _routes.add(Map<String, dynamic>.from(row));
        _routes.sort(
          (a, b) => a['route_name'].toString().toLowerCase().compareTo(
            b['route_name'].toString().toLowerCase(),
          ),
        );
        _selectedRouteId = row['id'].toString();
        _routeNameController.clear();
      });
      _message(
        _selectedCustomerIds.isEmpty
            ? 'Route created. Add its customers below.'
            : 'Route created with ${_selectedCustomerIds.length} customers.',
      );
    } catch (error) {
      debugPrint('Create route failed: $error');
      _message(
        'Could not create that route. Check whether the name already exists.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _renameRoute() async {
    final route = _selectedRoute;
    if (route == null) return;
    final controller = TextEditingController(
      text: route['route_name'].toString(),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename route'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Route name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save name'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null ||
        name.trim().isEmpty ||
        name.trim() == route['route_name']) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _client
          .from('salesman_route_templates')
          .update({
            'route_name': name.trim(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', route['id'].toString());
      if (!mounted) return;
      setState(() {
        final index = _routes.indexWhere(
          (r) => r['id'].toString() == route['id'].toString(),
        );
        if (index >= 0) {
          _routes[index] = {..._routes[index], 'route_name': name.trim()};
          _routes.sort(
            (a, b) => a['route_name'].toString().toLowerCase().compareTo(
              b['route_name'].toString().toLowerCase(),
            ),
          );
        }
      });
      _message('Route renamed to ${name.trim()}.');
    } catch (error) {
      debugPrint('Rename route failed: $error');
      _message(
        'Could not rename route. Make sure the name is not already in use.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveTemplateLocations() async {
    final route = _selectedRoute;
    if (route == null || _saving) return;
    final customerIds = _selectedCustomerIds.toList();
    final locations = _locationsForSelectedCustomers();
    setState(() => _saving = true);
    try {
      final savedRoute = await _client
          .from('salesman_route_templates')
          .update({
            'locations': locations,
            'customer_ids': customerIds,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', route['id'].toString())
          .select('id, locations, customer_ids')
          .single();
      if (!mounted) return;
      setState(() {
        final index = _routes.indexWhere(
          (r) => r['id'].toString() == route['id'].toString(),
        );
        if (index >= 0) {
          _routes[index] = {..._routes[index], ...savedRoute};
        }
      });
      _message('Customer selection saved for ${route['route_name']}.');
    } catch (error) {
      debugPrint('Save route locations failed: $error');
      _message('Could not save the customer selection. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectRouteCustomers() async {
    if (_saving) return;
    final eligible = List<Customer>.from(CustomerService.customers)
      ..sort(
        (a, b) => a.businessName.toLowerCase().compareTo(
          b.businessName.toLowerCase(),
        ),
      );
    // Editing must preserve saved IDs even when a customer is not currently
    // in the active customer list. Only an explicit removal changes membership.
    final selected = Set<String>.from(_selectedCustomerIds);
    var searchQuery = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final filteredEligible = eligible.where((customer) {
            final query = searchQuery.trim().toLowerCase();
            if (query.isEmpty) return true;
            return customer.businessName.toLowerCase().contains(query) ||
                customer.location.toLowerCase().contains(query) ||
                customer.phone.toLowerCase().contains(query);
          }).toList();
          return AlertDialog(
            title: Text(
              selected.isEmpty
                  ? 'Choose customers to visit'
                  : '${selected.length} customers selected',
            ),
            insetPadding: const EdgeInsets.all(16),
            content: SizedBox(
              width: math.min(620, MediaQuery.sizeOf(context).width - 48),
              height: MediaQuery.sizeOf(context).height * 0.68,
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Select only the customers this route should include. '
                      'Only customers you select here will be assigned and shown to salesmen. '
                      'A customer may be assigned to more than one salesman.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search customers',
                      hintText: 'Search by name, location, or phone',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => searchQuery = value),
                  ),
                  const SizedBox(height: 10),
                  _actionRow([
                    _outlinedAction(
                      icon: Icons.visibility_outlined,
                      label: 'View selected',
                      onPressed: selected.isEmpty
                          ? null
                          : () async {
                              await _showSelectedCustomers(
                                dialogContext,
                                selected,
                                eligible,
                              );
                              setDialogState(() {});
                            },
                    ),
                    _outlinedAction(
                      icon: Icons.clear_all_rounded,
                      label: 'Clear all',
                      onPressed: selected.isEmpty
                          ? null
                          : () => setDialogState(() => selected.clear()),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  if (eligible.isEmpty)
                    const Expanded(
                      child: Center(child: Text('No active customers found.')),
                    )
                  else if (filteredEligible.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text('No matching customers found.'),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView(
                        children: filteredEligible.map((customer) {
                          final otherSalesmen =
                              _otherSalesmenAssignedToCustomer(customer.id);
                          return CheckboxListTile(
                            key: ValueKey(customer.id),
                            value: selected.contains(customer.id),
                            title: Text(customer.businessName),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(customer.location),
                                const SizedBox(height: 2),
                                Text(
                                  CurrencyFormatter.customerBalance(
                                    TransactionService.getCustomerBalance(
                                      customer.id,
                                    ),
                                  ),
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (otherSalesmen.isNotEmpty)
                                  Text(
                                    'Also assigned to: ${otherSalesmen.join(', ')}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.secondary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                              ],
                            ),
                            onChanged: (checked) => setDialogState(() {
                              if (checked == true) {
                                selected.add(customer.id);
                              } else {
                                selected.remove(customer.id);
                              }
                            }),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext, true);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _selectedCustomerIds = Set<String>.from(selected));
      await _saveTemplateLocations();
    }
  }

  Future<void> _showSelectedCustomers(
    BuildContext parentContext,
    Set<String> selected,
    List<Customer> eligible,
  ) async {
    // Show customers in route order (the order they were selected), which is
    // the same order and numbering the salesman sees.
    final byId = {for (final customer in eligible) customer.id: customer};
    final selectedCustomers = selected
        .map((id) => byId[id])
        .whereType<Customer>()
        .toList();
    await showDialog<void>(
      context: parentContext,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${selected.length} customers selected'),
          content: SizedBox(
            width: 520,
            height: 460,
            child: selectedCustomers.isEmpty
                ? const Center(child: Text('No customers selected.'))
                : ListView.separated(
                    itemCount: selectedCustomers.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final customer = selectedCustomers[index];
                      return ListTile(
                        dense: true,
                        leading: SizedBox(
                          width: 32,
                          child: Text(
                            '${index + 1}.',
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        title: Text(customer.businessName),
                        subtitle: Text(customer.location),
                        trailing: IconButton(
                          tooltip: 'Remove customer',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () {
                            selected.remove(customer.id);
                            selectedCustomers.removeAt(index);
                            setDialogState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectRouteLocations() async {
    final eligible = CustomerService.customers
        .where(
          (customer) =>
              TransactionService.getCustomerBalance(customer.id) > 0 &&
              customer.location.trim().isNotEmpty,
        )
        .toList();
    final customersByLocation = <String, List<Customer>>{};
    for (final customer in eligible) {
      final location = customer.location.trim();
      customersByLocation.putIfAbsent(location, () => []).add(customer);
    }
    final locations = customersByLocation.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    // Location additions are intentionally fresh. Existing selected customers
    // may represent only part of a location, so preselecting that location
    // would accidentally add every customer in it.
    final selectedLocations = <String>{};
    var searchQuery = '';
    var applied = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = searchQuery.trim().toLowerCase();
          final filteredLocations = locations
              .where((location) => location.toLowerCase().contains(query))
              .toList();
          return AlertDialog(
            title: Text(
              selectedLocations.isEmpty
                  ? 'Choose route locations'
                  : '${selectedLocations.length} locations selected',
            ),
            insetPadding: const EdgeInsets.all(16),
            content: SizedBox(
              width: math.min(560, MediaQuery.sizeOf(context).width - 48),
              height: math.min(520, MediaQuery.sizeOf(context).height * .62),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'All customers with a pending balance in the selected locations will be added to this route.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Search locations',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => searchQuery = value),
                  ),
                  const SizedBox(height: 10),
                  _outlinedAction(
                    icon: Icons.clear_all_rounded,
                    label: 'Clear all',
                    onPressed: selectedLocations.isEmpty
                        ? null
                        : () => setDialogState(selectedLocations.clear),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: locations.isEmpty
                        ? const Center(
                            child: Text(
                              'No customer locations with pending balances found.',
                            ),
                          )
                        : filteredLocations.isEmpty
                        ? const Center(
                            child: Text('No matching locations found.'),
                          )
                        : ListView.builder(
                            itemCount: filteredLocations.length,
                            itemBuilder: (context, index) {
                              final location = filteredLocations[index];
                              final count =
                                  customersByLocation[location]!.length;
                              return CheckboxListTile(
                                value: selectedLocations.contains(location),
                                contentPadding: EdgeInsets.zero,
                                title: Text(location),
                                subtitle: Text(
                                  '$count customer${count == 1 ? '' : 's'} with a pending balance',
                                ),
                                onChanged: (checked) => setDialogState(() {
                                  if (checked == true) {
                                    selectedLocations.add(location);
                                  } else {
                                    selectedLocations.remove(location);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final selectedIds = <String>{
                    for (final location in selectedLocations)
                      ...customersByLocation[location]!.map(
                        (customer) => customer.id,
                      ),
                  };
                  // Location selection is additive: owners can include all
                  // customers in selected areas, then add specific customers
                  // from any other area through the customer picker.
                  setState(
                    () => _selectedCustomerIds = {
                      ..._selectedCustomerIds,
                      ...selectedIds,
                    },
                  );
                  applied = selectedIds.isNotEmpty;
                  Navigator.pop(dialogContext);
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
    if (applied && mounted && _selectedRoute != null) {
      await _saveTemplateLocations();
    }
  }

  Future<void> _assignForToday() async {
    final route = _selectedRoute;
    final salesmanIds = _selectedSalesmanIds.toList();
    if (route == null || salesmanIds.isEmpty) {
      _message('Create a route and select at least one salesman first.');
      return;
    }
    if (_selectedCustomerIds.isEmpty) {
      _message('Select at least one customer first.');
      return;
    }
    setState(() => _saving = true);
    try {
      final companyId = await _requireCompanyId();
      final locations = _locationsForSelectedCustomers();
      // The latest dated assignment remains active until the owner removes it.
      // Keep the saved named route in sync so salesmen can display its name.
      await _client
          .from('salesman_route_templates')
          .update({
            'company_id': companyId,
            'locations': locations,
            'customer_ids': _selectedCustomerIds.toList(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', route['id'].toString());
      final assignmentStates = await Future.wait(
        salesmanIds.map(
          (salesmanId) async => MapEntry(
            salesmanId,
            (await _client.rpc(
              'queue_or_assign_salesman_route',
              params: {
                'p_salesman_id': salesmanId,
                'p_locations': locations,
                'p_customer_ids': _selectedCustomerIds.toList(),
              },
            )).toString(),
          ),
        ),
      );
      final activeSalesmanIds = assignmentStates
          .where((entry) => entry.value == 'active')
          .map((entry) => entry.key)
          .toSet();
      final queuedCount = assignmentStates
          .where((entry) => entry.value == 'queued')
          .length;

      if (!mounted) return;
      setState(() {
        final routeIndex = _routes.indexWhere(
          (item) => item['id'].toString() == route['id'].toString(),
        );
        if (routeIndex >= 0) {
          _routes[routeIndex] = {
            ..._routes[routeIndex],
            'locations': locations,
            'customer_ids': _selectedCustomerIds.toList(),
          };
        }
        for (final salesmanId in activeSalesmanIds) {
          _todayAssignments[salesmanId] = locations;
          _todayCustomerAssignments[salesmanId] = List<String>.from(
            _selectedCustomerIds,
          );
        }
      });
      final activeCount = activeSalesmanIds.length;
      _message(
        [
          if (activeCount > 0)
            'Route activated for $activeCount salesman${activeCount == 1 ? '' : 's'}',
          if (queuedCount > 0)
            'queued for $queuedCount salesman${queuedCount == 1 ? '' : 's'} until their current route is finished',
        ].join('; '),
      );
      await _load();
    } catch (error) {
      debugPrint('Assign daily route failed: $error');
      _message(
        'Could not assign today’s route. Please check the route database setup.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeTodayAssignment({
    required String salesmanId,
    required String salesmanName,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove route assignment?'),
        content: Text(
          'Remove the active route assignment for $salesmanName? The saved route and past assignment records will remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove assignment'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final activation = await _client.rpc(
        'activate_next_salesman_route',
        params: {'p_salesman_id': salesmanId, 'p_allow_owner': true},
      );
      if (!mounted) return;
      await _load();
      _message(
        activation.toString() == 'next_route_activated'
            ? 'Current route removed for $salesmanName. The next queued route is now active.'
            : 'Route assignment removed for $salesmanName.',
      );
    } catch (error) {
      debugPrint('Remove daily route failed: $error');
      _message('Could not remove today’s route. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addCustomersToSalesman({
    required String salesmanId,
    required String salesmanName,
  }) async {
    final assignedIds = List<String>.from(
      _todayCustomerAssignments[salesmanId] ?? const <String>[],
    );
    if (assignedIds.isEmpty) {
      _message('Assign a route to this salesman before adding customers.');
      return;
    }

    final activeSalesmen = _salesmen
        .where(
          (salesman) =>
              (_todayCustomerAssignments[(salesman['id'] ?? '').toString()] ??
                      const <String>[])
                  .isNotEmpty,
        )
        .toList();
    final selectedIds = <String>[];
    final selectedSalesmanIds = <String>{salesmanId};
    var searchQuery = '';
    var insertBeforeCustomerId = '';
    final screenSize = MediaQuery.sizeOf(context);
    final customerById = {
      for (final customer in CustomerService.customers) customer.id: customer,
    };
    final assignmentRequest = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = searchQuery.trim().toLowerCase();
          final selectedAssignments = selectedSalesmanIds
              .map((id) => _todayCustomerAssignments[id] ?? const <String>[])
              .toList();
          final availableCustomers =
              CustomerService.customers.where((customer) {
                final hasBalance =
                    TransactionService.getCustomerBalance(customer.id) > 0;
                final needsAssignment = selectedAssignments.any(
                  (ids) => !ids.contains(customer.id),
                );
                final matchesSearch =
                    query.isEmpty ||
                    customer.businessName.toLowerCase().contains(query) ||
                    customer.location.toLowerCase().contains(query) ||
                    customer.phone.toLowerCase().contains(query);
                return hasBalance && needsAssignment && matchesSearch;
              }).toList()..sort(
                (a, b) => a.businessName.toLowerCase().compareTo(
                  b.businessName.toLowerCase(),
                ),
              );
          return AlertDialog(
            title: const Text('Add customers to salesman routes'),
            insetPadding: const EdgeInsets.all(16),
            content: SizedBox(
              width: math.min(560, screenSize.width - 48),
              height: screenSize.height * .72,
              // Small or sideways screens scroll instead of overflowing.
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: SizedBox(
                    height: math.max(constraints.maxHeight, 560),
                    child: Column(
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      'Select one or more salesmen, then choose customers. The chosen position applies to $salesmanName’s route; customers are appended to the other selected routes. Existing visit history stays unchanged.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Salesmen',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setDialogState(() {
                          selectedSalesmanIds
                            ..clear()
                            ..addAll(
                              activeSalesmen.map(
                                (salesman) => (salesman['id'] ?? '').toString(),
                              ),
                            );
                        }),
                        child: const Text('Select all'),
                      ),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 104),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: activeSalesmen.map((salesman) {
                          final id = (salesman['id'] ?? '').toString();
                          return FilterChip(
                            label: Text(
                              (salesman['name'] ?? 'Salesman').toString(),
                            ),
                            selected: selectedSalesmanIds.contains(id),
                            onSelected: (selected) => setDialogState(() {
                              if (selected) {
                                selectedSalesmanIds.add(id);
                              } else if (id != salesmanId) {
                                selectedSalesmanIds.remove(id);
                              }
                            }),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      selectedSalesmanIds.isEmpty
                          ? 'Select at least one salesman.'
                          : 'Selected: ${selectedSalesmanIds.map((id) => activeSalesmen.firstWhere((salesman) => (salesman['id'] ?? '').toString() == id, orElse: () => {'name': 'Salesman'})['name']).join(', ')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: insertBeforeCustomerId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Position on $salesmanName’s route',
                    ),
                    items: [
                      DropdownMenuItem<String>(
                        value: '',
                        child: Text('At end (${assignedIds.length + 1})'),
                      ),
                      ...assignedIds.asMap().entries.map((entry) {
                        final customerName =
                            customerById[entry.value]?.businessName ??
                            'Assigned customer';
                        return DropdownMenuItem<String>(
                          value: entry.value,
                          child: Text(
                            '${entry.key + 1}. $customerName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }),
                    ],
                    onChanged: (value) => setDialogState(
                      () => insertBeforeCustomerId = value ?? '',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search customers',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => searchQuery = value),
                  ),
                  const SizedBox(height: 8),
                  if (selectedIds.isNotEmpty) ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'New customer order: ${selectedIds.map((id) => customerById[id]?.businessName ?? 'Customer').join(' → ')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: selectedSalesmanIds.isEmpty
                        ? const Center(
                            child: Text('Select a salesman to see customers.'),
                          )
                        : availableCustomers.isEmpty
                        ? const Center(
                            child: Text(
                              'No additional customers with a pending balance are available for these salesmen.',
                            ),
                          )
                        : ListView.builder(
                            itemCount: availableCustomers.length,
                            itemBuilder: (context, index) {
                              final customer = availableCustomers[index];
                              final selected = selectedIds.contains(
                                customer.id,
                              );
                              final alreadyAssignedTo = selectedSalesmanIds
                                  .where(
                                    (id) =>
                                        (_todayCustomerAssignments[id] ??
                                                const <String>[])
                                            .contains(customer.id),
                                  )
                                  .map(
                                    (id) => activeSalesmen
                                        .firstWhere(
                                          (salesman) =>
                                              (salesman['id'] ?? '')
                                                  .toString() ==
                                              id,
                                          orElse: () => {'name': 'Salesman'},
                                        )['name']
                                        .toString(),
                                  )
                                  .toList();
                              final willBeAddedTo = selectedSalesmanIds
                                  .where(
                                    (id) =>
                                        !(_todayCustomerAssignments[id] ??
                                                const <String>[])
                                            .contains(customer.id),
                                  )
                                  .map(
                                    (id) => activeSalesmen
                                        .firstWhere(
                                          (salesman) =>
                                              (salesman['id'] ?? '')
                                                  .toString() ==
                                              id,
                                          orElse: () => {'name': 'Salesman'},
                                        )['name']
                                        .toString(),
                                  )
                                  .toList();
                              return CheckboxListTile(
                                value: selected,
                                title: Text(
                                  customer.businessName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${customer.location} · ${CurrencyFormatter.customerBalance(TransactionService.getCustomerBalance(customer.id))}\n${alreadyAssignedTo.isEmpty ? '' : 'Already on: ${alreadyAssignedTo.join(', ')} · '}${willBeAddedTo.isEmpty ? 'Already on all selected routes' : 'Will add to: ${willBeAddedTo.join(', ')}'}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onChanged: (checked) => setDialogState(() {
                                  if (checked == true) {
                                    if (!selectedIds.contains(customer.id)) {
                                      selectedIds.add(customer.id);
                                    }
                                  } else {
                                    selectedIds.remove(customer.id);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                ],
                    ),
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
                onPressed: selectedIds.isEmpty || selectedSalesmanIds.isEmpty
                    ? null
                    : () => Navigator.pop<Map<String, dynamic>>(dialogContext, {
                        'customerIds': List<String>.from(selectedIds),
                        'salesmanIds': selectedSalesmanIds.toList(),
                        'insertBeforeCustomerId': insertBeforeCustomerId,
                      }),
                child: Text(
                  selectedIds.isEmpty
                      ? 'Choose customers'
                      : 'Add ${selectedIds.length} customer${selectedIds.length == 1 ? '' : 's'}',
                ),
              ),
            ],
          );
        },
      ),
    );
    if (assignmentRequest == null || !mounted) return;
    final customersToAdd = List<String>.from(
      assignmentRequest['customerIds'] as List,
    );
    final recipientIds = List<String>.from(
      assignmentRequest['salesmanIds'] as List,
    );
    final requestedPosition =
        (assignmentRequest['insertBeforeCustomerId'] ?? '').toString();
    if (customersToAdd.isEmpty || recipientIds.isEmpty) return;

    setState(() => _saving = true);
    try {
      final companyId = await _requireCompanyId();
      final now = DateTime.now();
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      List<String> decodeStringList(dynamic value) {
        if (value is List) return value.map((item) => item.toString()).toList();
        if (value is String && value.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is List) {
              return decoded.map((item) => item.toString()).toList();
            }
          } catch (_) {}
        }
        return <String>[];
      }

      final currentRows = await Future.wait(
        recipientIds.map(
          (recipientId) => _client
              .from('salesman_daily_route_selections')
              .select('salesman_id, locations, customer_ids')
              .eq('company_id', companyId)
              .eq('salesman_id', recipientId)
              .eq('route_date', dateKey)
              .maybeSingle(),
        ),
      );
      final assignments = <Map<String, dynamic>>[];
      final nextCustomersBySalesman = <String, List<String>>{};
      final nextLocationsBySalesman = <String, List<String>>{};
      var totalAdded = 0;

      for (var index = 0; index < recipientIds.length; index++) {
        final recipientId = recipientIds[index];
        final currentRow = currentRows[index];
        if (currentRow == null) {
          throw StateError(
            'A selected salesman no longer has an active route today.',
          );
        }

        final savedIds = decodeStringList(currentRow['customer_ids']);
        final nextIds = savedIds.isEmpty
            ? List<String>.from(
                _todayCustomerAssignments[recipientId] ?? const <String>[],
              )
            : savedIds;
        final nextIdSet = nextIds.toSet();
        final newIds = customersToAdd
            .where((id) => nextIdSet.add(id))
            .toList(growable: false);
        if (newIds.isEmpty) continue;

        final isPositionSalesman = recipientId == salesmanId;
        final selectedPosition =
            isPositionSalesman && requestedPosition.isNotEmpty
            ? nextIds.indexOf(requestedPosition)
            : -1;
        final insertionIndex = selectedPosition < 0
            ? nextIds.length
            : selectedPosition;
        nextIds.insertAll(insertionIndex, newIds);

        final previousLocations = decodeStringList(currentRow['locations']);
        final nextLocations = <String>[];
        final locationKeys = <String>{};
        for (final id in nextIds) {
          final location = customerById[id]?.location.trim() ?? '';
          if (location.isNotEmpty && locationKeys.add(location.toLowerCase())) {
            nextLocations.add(location);
          }
        }
        for (final location in previousLocations) {
          final cleaned = location.trim();
          if (cleaned.isNotEmpty && locationKeys.add(cleaned.toLowerCase())) {
            nextLocations.add(cleaned);
          }
        }

        assignments.add({
          'company_id': companyId,
          'salesman_id': recipientId,
          'route_date': dateKey,
          'locations': nextLocations,
          'customer_ids': nextIds,
        });
        nextCustomersBySalesman[recipientId] = nextIds;
        nextLocationsBySalesman[recipientId] = nextLocations;
        totalAdded += newIds.length;
      }

      if (assignments.isEmpty) {
        _message(
          'Those customers are already assigned to all selected salesmen.',
        );
        return;
      }
      await _client
          .from('salesman_daily_route_selections')
          .upsert(assignments, onConflict: 'salesman_id,route_date');
      if (!mounted) return;
      setState(() {
        _todayAssignments.addAll(nextLocationsBySalesman);
        _todayCustomerAssignments.addAll(nextCustomersBySalesman);
      });
      _message(
        'Added $totalAdded customer assignment${totalAdded == 1 ? '' : 's'} across ${assignments.length} salesman route${assignments.length == 1 ? '' : 's'}. Visit history was preserved.',
      );
    } catch (error) {
      debugPrint('Add customers to salesman route failed: $error');
      _message('Could not add customers to this route. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeCustomerFromSalesmanRoute({
    required String salesmanId,
    required String salesmanName,
    required Customer customer,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove customer from route?'),
        content: Text(
          'Remove ${customer.businessName} from $salesmanName’s active route? The customer, payments, and visit history will remain unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove from route'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final companyId = await _requireCompanyId();
      final now = DateTime.now();
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final currentRow = await _client
          .from('salesman_daily_route_selections')
          .select('locations, customer_ids')
          .eq('company_id', companyId)
          .eq('salesman_id', salesmanId)
          .eq('route_date', dateKey)
          .maybeSingle();
      if (currentRow == null) {
        throw StateError('This salesman no longer has an active route today.');
      }

      List<String> decodeStringList(dynamic value) {
        if (value is List) return value.map((item) => item.toString()).toList();
        if (value is String && value.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is List) {
              return decoded.map((item) => item.toString()).toList();
            }
          } catch (_) {}
        }
        return <String>[];
      }

      final savedIds = decodeStringList(currentRow['customer_ids']);
      final currentIds = savedIds.isEmpty
          ? List<String>.from(
              _todayCustomerAssignments[salesmanId] ?? const <String>[],
            )
          : savedIds;
      if (!currentIds.contains(customer.id)) {
        _message('This customer is already removed from the route.');
        return;
      }
      final nextIds = currentIds
          .where((id) => id != customer.id)
          .toList(growable: false);
      final customerById = {
        for (final item in CustomerService.customers) item.id: item,
      };
      final nextLocations = <String>[];
      final locationKeys = <String>{};
      for (final id in nextIds) {
        final location = customerById[id]?.location.trim() ?? '';
        if (location.isNotEmpty && locationKeys.add(location.toLowerCase())) {
          nextLocations.add(location);
        }
      }

      await _client.from('salesman_daily_route_selections').upsert({
        'company_id': companyId,
        'salesman_id': salesmanId,
        'route_date': dateKey,
        'locations': nextLocations,
        'customer_ids': nextIds,
      }, onConflict: 'salesman_id,route_date');
      if (!mounted) return;
      setState(() {
        _todayAssignments[salesmanId] = nextLocations;
        _todayCustomerAssignments[salesmanId] = nextIds;
      });
      _message(
        '${customer.businessName} was removed from $salesmanName’s route.',
      );
    } catch (error) {
      debugPrint('Remove customer from salesman route failed: $error');
      _message(
        'Could not remove this customer from the route. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _printAssignedCustomers({
    required String salesmanName,
    required String routeName,
    required List<Customer> customers,
  }) async {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (_) => [
          pw.Text(
            'Assigned customers',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text('Salesman: $salesmanName'),
          if (routeName.isNotEmpty) pw.Text('Route: $routeName'),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Customer', 'Location', 'Phone'],
            data: [
              for (var i = 0; i < customers.length; i++)
                [
                  '${i + 1}',
                  customers[i].businessName,
                  customers[i].location,
                  customers[i].phone,
                ],
            ],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellPadding: const pw.EdgeInsets.all(5),
          ),
        ],
      ),
    );
    final bytes = await document.save();
    if (Platform.isAndroid || Platform.isIOS) {
      await Printing.sharePdf(bytes: bytes, filename: 'assigned_route.pdf');
      return;
    }
    if (Platform.isMacOS) {
      final safeName = salesmanName
          .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      final location = await getSaveLocation(
        suggestedName: '${safeName.isEmpty ? 'salesman' : safeName}_route.pdf',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PDF Document', extensions: ['pdf']),
        ],
      );
      if (location != null) {
        await XFile.fromData(
          bytes,
          name: 'assigned_route.pdf',
          mimeType: 'application/pdf',
        ).saveTo(location.path);
      }
      return;
    }
    try {
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      // Some Windows/macOS builds do not expose a printer service. Fall back
      // to saving the generated PDF so the route list is still usable.
      debugPrint('Printing unavailable, saving route list instead: $error');
      final safeName = salesmanName
          .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      final location = await getSaveLocation(
        suggestedName: '${safeName.isEmpty ? 'salesman' : safeName}_route.pdf',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PDF Document', extensions: ['pdf']),
        ],
      );
      if (location != null) {
        await XFile.fromData(
          bytes,
          name: 'assigned_route.pdf',
          mimeType: 'application/pdf',
        ).saveTo(location.path);
      }
    }
  }

  Future<void> _deleteRoute() async {
    final route = _selectedRoute;
    if (route == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text(
          'Delete the saved route “${route['route_name']}”? Past daily assignments will not be changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _client
          .from('salesman_route_templates')
          .delete()
          .eq('id', route['id'].toString());
      if (!mounted) return;
      setState(() {
        _routes.removeWhere(
          (r) => r['id'].toString() == route['id'].toString(),
        );
        _selectedRouteId = _routes.isEmpty
            ? null
            : _routes.first['id'].toString();
      });
      _message('Route deleted.');
    } catch (error) {
      debugPrint('Delete route failed: $error');
      _message('Could not delete this route. Please try again.');
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surfaceContainerLowest,
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: SydexScreenHeader(
                eyebrow: switch (widget.page) {
                  OwnerRoutePage.places => 'Places & routes',
                  OwnerRoutePage.salesmen => 'Salesmen & assigned routes',
                  OwnerRoutePage.map => 'Customer locations and visits',
                },
                title: switch (widget.page) {
                  OwnerRoutePage.places => 'Routes',
                  OwnerRoutePage.salesmen => 'Salesmen',
                  OwnerRoutePage.map => 'Visit audit',
                },
                leading: sydexCanGoBack(context)
                    ? SydexIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    : null,
                actions: [
                  if (widget.page == OwnerRoutePage.places)
                    OutlinedButton.icon(
                      onPressed: _openSalesmenPage,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      icon: const Icon(Icons.badge_outlined, size: 18),
                      label: const Text('Salesmen'),
                    ),
                  SydexIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Refresh',
                    onPressed: () {
                      _load();
                      if (widget.page == OwnerRoutePage.map) _loadMapVisits();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
          : widget.page == OwnerRoutePage.places
          ? _buildPlacesPage()
          : widget.page == OwnerRoutePage.salesmen
          ? _buildSalesmenPage()
          : _buildMapPage(),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSalesmenPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            const OwnerRouteManagementScreen(page: OwnerRoutePage.salesmen),
      ),
    );
  }

  Widget _stepTitle(String title, [String? hint]) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              hint,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  static const _actionHeight = Size.fromHeight(46);

  /// Every button on this page sits in a row of equal-width buttons, so they
  /// line up with the fields above them on any screen size.
  Widget _actionRow(List<Widget> buttons) => Row(
    children: [
      for (final (index, button) in buttons.indexed) ...[
        if (index > 0) const SizedBox(width: 10),
        Expanded(child: button),
      ],
    ],
  );

  Widget _outlinedAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    String? tooltip,
    bool danger = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: _actionHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: danger ? colors.error : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(label, maxLines: 1),
          ],
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _primaryAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: _actionHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label, maxLines: 1),
        ],
      ),
    ),
  );

  Future<void> _viewSelection() async {
    final before = _selectedCustomerIds.length;
    await _showSelectedCustomers(
      context,
      _selectedCustomerIds,
      CustomerService.customers,
    );
    if (!mounted) return;
    setState(() {});
    if (_selectedCustomerIds.length != before && _selectedRoute != null) {
      await _saveTemplateLocations();
    }
  }

  void _chooseRoute(String? id) {
    setState(() {
      _selectedRouteId = id;
      _selectedSalesmanIds.clear();
      final rawCustomerIds = _selectedRoute?['customer_ids'];
      // A saved route is authoritative. Do not merge the previous route's
      // selection, which caused unrelated customers to be counted.
      _selectedCustomerIds = rawCustomerIds is List
          ? rawCustomerIds.map((value) => value.toString()).toSet()
          : rawCustomerIds is String
          ? _decodeCustomerIds(rawCustomerIds)
          : <String>{};
    });
  }

  Widget _buildPlacesPage() {
    final phone = MediaQuery.sizeOf(context).width < 600;
    return ListView(
      padding: EdgeInsets.fromLTRB(phone ? 20 : 24, 10, phone ? 20 : 24, 24),
      children: [
        SydexTwoColumn(
          breakpoint: 820,
          primary: [
            _newRouteCard(),
            const SizedBox(height: 12),
            _editRouteCard(),
          ],
          secondary: [_assignRouteCard()],
        ),
      ],
    );
  }

  Widget _newRouteCard() => SydexCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepTitle('New route'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final field = TextField(
              controller: _routeNameController,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_saving) _createRoute();
              },
              decoration: const InputDecoration(
                labelText: 'Route name',
                hintText: 'e.g. ABC Route',
              ),
            );
            final create = _primaryAction(
              icon: Icons.add_rounded,
              label: 'Create route',
              onPressed: _saving ? null : _createRoute,
            );
            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [field, const SizedBox(height: 10), create],
              );
            }
            return Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 10),
                SizedBox(width: 150, height: 52, child: create),
              ],
            );
          },
        ),
      ],
    ),
  );

  Widget _editRouteCard() {
    final colors = Theme.of(context).colorScheme;
    final canEdit = !_saving && _selectedRoute != null;
    final count = _selectedCustomerCount;
    final locations = _locationsForSelectedCustomers();
    return SydexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            'Saved route',
            'Choose a route, then choose who to visit on it.',
          ),
          const SizedBox(height: 16),
          if (_routes.isEmpty)
            Text(
              'Create your first route to get started.',
              style: TextStyle(color: colors.onSurfaceVariant),
            )
          else
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: ValueKey(_selectedRouteId),
              initialValue: _selectedRouteId,
              decoration: const InputDecoration(labelText: 'Route'),
              items: _routes
                  .map(
                    (route) => DropdownMenuItem<String>(
                      value: route['id'].toString(),
                      child: Text(
                        route['route_name'].toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _chooseRoute,
            ),
          const SizedBox(height: 10),
          _actionRow([
            _outlinedAction(
              icon: Icons.edit_outlined,
              label: 'Rename',
              tooltip: 'Rename route',
              onPressed: canEdit ? _renameRoute : null,
            ),
            _outlinedAction(
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              tooltip: 'Delete route',
              danger: canEdit,
              onPressed: canEdit ? _deleteRoute : null,
            ),
          ]),
          const SizedBox(height: 18),
          Divider(height: 1, color: colors.outlineVariant),
          const SizedBox(height: 16),
          _stepTitle(
            'Customers on this route',
            'Only the customers you choose are shown to the salesman.',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            constraints: const BoxConstraints(minHeight: 56),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.people_alt_outlined,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        count == 0
                            ? 'No customers selected'
                            : '$count customer${count == 1 ? '' : 's'} selected',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (locations.isNotEmpty)
                        Text(
                          locations.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (count > 0)
                  TextButton(
                    onPressed: _saving ? null : _viewSelection,
                    child: const Text('View'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _actionRow([
            _outlinedAction(
              icon: Icons.person_add_alt_1_outlined,
              label: 'Add customers',
              onPressed: canEdit ? _selectRouteCustomers : null,
            ),
            _outlinedAction(
              icon: Icons.add_location_alt_outlined,
              label: 'Add locations',
              // Locations can be prepared before a route is chosen; they are
              // applied to the route on save.
              onPressed: _saving ? null : _selectRouteLocations,
            ),
          ]),
          const SizedBox(height: 10),
          _primaryAction(
            icon: Icons.check_rounded,
            label: 'Save route',
            onPressed: canEdit ? _saveTemplateLocations : null,
          ),
        ],
      ),
    );
  }

  Widget _assignRouteCard() {
    final colors = Theme.of(context).colorScheme;
    final chosen = _selectedSalesmanIds.length;
    return SydexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            'Assign to salesmen',
            'The route stays assigned until you remove it. A customer can be on more than one salesman’s route.',
          ),
          const SizedBox(height: 8),
          if (_salesmen.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No salesman accounts were found. Add a user with the Salesman role first.',
                style: TextStyle(color: colors.error),
              ),
            ),
          for (final (index, salesman) in _salesmen.indexed) ...[
            if (index > 0) Divider(height: 1, color: colors.outlineVariant),
            _salesmanChoice(salesman),
          ],
          const SizedBox(height: 10),
          _primaryAction(
            icon: Icons.route_outlined,
            label: chosen == 0
                ? 'Assign route'
                : 'Assign route to $chosen salesm${chosen == 1 ? 'a' : 'e'}n',
            onPressed:
                _saving ||
                    _selectedRoute == null ||
                    _selectedSalesmanIds.isEmpty ||
                    _selectedCustomerIds.isEmpty
                ? null
                : _assignForToday,
          ),
        ],
      ),
    );
  }

  Widget _salesmanChoice(Map<String, dynamic> salesman) {
    final salesmanId = salesman['id'].toString();
    final name = (salesman['name'] ?? 'Salesman').toString();
    final assigned = (_todayCustomerAssignments[salesmanId] ?? const <String>[])
        .toSet()
        .length;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.trailing,
      secondary: SydexAvatar(name, size: 36),
      value: _selectedSalesmanIds.contains(salesmanId),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        assigned == 0
            ? 'No customers assigned'
            : '$assigned customer${assigned == 1 ? '' : 's'} assigned',
      ),
      onChanged: (selected) {
        setState(() {
          if (selected == true) {
            _selectedSalesmanIds.add(salesmanId);
          } else {
            _selectedSalesmanIds.remove(salesmanId);
          }
        });
      },
    );
  }

  Widget _buildSalesmenPage() {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        MediaQuery.sizeOf(context).width < 600 ? 20 : 24,
        8,
        MediaQuery.sizeOf(context).width < 600 ? 20 : 24,
        24,
      ),
      children: [
        Text(
          'Assignments stay active until you remove them. Open Places & Routes to create or edit a named route and assign it.',
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (_salesmen.isEmpty)
          const Text('No salesman accounts were found.')
        else ...[
          Builder(
            builder: (context) {
              final names = <String, String>{'All salesmen': ''};
              for (final salesman in _salesmen) {
                var name = (salesman['name'] ?? 'Salesman').toString();
                while (names.containsKey(name)) {
                  name = '$name ';
                }
                names[name] = salesman['id'].toString();
              }
              final selected = names.entries
                  .firstWhere(
                    (entry) => entry.value == _salesmanFilterId,
                    orElse: () => names.entries.first,
                  )
                  .key;
              return SydexChoiceChips(
                options: names.keys.toList(),
                selected: selected,
                onSelected: (name) =>
                    setState(() => _salesmanFilterId = names[name] ?? ''),
              );
            },
          ),
          const SizedBox(height: 16),
          ..._salesmen
              .where((salesman) {
                return _salesmanFilterId.isEmpty ||
                    salesman['id'].toString() == _salesmanFilterId;
              })
              .map((salesman) {
                final salesmanId = (salesman['id'] ?? '').toString();
                final assignedLocations =
                    _todayAssignments[salesmanId] ?? const <String>[];
                final normalizedAssigned = [...assignedLocations]
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                String? assignedRouteName;
                for (final route in _routes) {
                  final templateLocations =
                      (route['locations'] as List? ?? const [])
                          .map((e) => e.toString())
                          .toList()
                        ..sort(
                          (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                        );
                  if (templateLocations.length == normalizedAssigned.length &&
                      List.generate(
                        templateLocations.length,
                        (i) => templateLocations[i] == normalizedAssigned[i],
                      ).every((same) => same)) {
                    assignedRouteName = route['route_name'].toString();
                    break;
                  }
                }
                // The salesman card must count only customers that are
                // actually assigned to that salesman. Remove stale IDs and
                // de-duplicate legacy assignment rows before displaying the
                // count or list.
                final knownCustomerIds = CustomerService.customers
                    .map((customer) => customer.id)
                    .toSet();
                final assignedIds = <String>[];
                for (final id
                    in _todayCustomerAssignments[salesmanId] ??
                        const <String>[]) {
                  if (knownCustomerIds.contains(id) &&
                      !assignedIds.contains(id)) {
                    assignedIds.add(id);
                  }
                }
                final queuedIds = <String>{
                  ...?_queuedCustomerAssignments[salesmanId],
                };
                final customerSerialNumbers = {
                  for (var index = 0; index < assignedIds.length; index++)
                    assignedIds[index]: index + 1,
                };
                final subtitle = assignedIds.isEmpty && queuedIds.isEmpty
                    ? 'No active route assignment'
                    : '${assignedRouteName == null ? 'Assigned customers' : 'Route: $assignedRouteName'}\n${assignedIds.length} active customers${queuedIds.isEmpty ? '' : ' • ${queuedIds.length} next route queued'}';
                // Customer IDs are the single source of truth for assignments.
                final routeCustomers = CustomerService.customers.where((
                  customer,
                ) {
                  if (assignedIds.isNotEmpty) {
                    return assignedIds.contains(customer.id);
                  }
                  return false;
                }).toList();
                if (assignedIds.isNotEmpty) {
                  final order = {
                    for (var i = 0; i < assignedIds.length; i++)
                      assignedIds[i]: i,
                  };
                  routeCustomers.sort(
                    (a, b) => (order[a.id] ?? 999999).compareTo(
                      order[b.id] ?? 999999,
                    ),
                  );
                }
                final customerFilter =
                    _customerFiltersBySalesman[salesmanId] ?? 'All';
                bool matchesFilter(Customer customer, String filter) {
                  final status =
                      _todayCustomerStatusesBySalesman[salesmanId]?[customer
                          .id];
                  final visited = status == 'paid' || status == 'rejected';
                  return switch (filter) {
                    'Pending' => !visited,
                    'Visited' => visited,
                    _ => true,
                  };
                }

                final query = _customerSearchBySalesman[salesmanId] ?? '';
                final searchedCustomers = routeCustomers.where((customer) {
                  return query.isEmpty ||
                      customer.businessName.toLowerCase().contains(query) ||
                      customer.location.toLowerCase().contains(query);
                }).toList();
                final visibleCustomers = searchedCustomers
                    .where(
                      (customer) => matchesFilter(customer, customerFilter),
                    )
                    .toList();
                return Card(
                  key: ValueKey(salesmanId),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: SydexAvatar(
                          (salesman['name'] ?? 'Salesman').toString(),
                        ),
                        title: Text(
                          (salesman['name'] ?? 'Salesman').toString(),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(subtitle),
                            if (queuedIds.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              const SydexBadge(
                                'Next route queued',
                                tone: SydexTone.info,
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (assignedIds.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: _actionRow([
                            _outlinedAction(
                              icon: Icons.person_add_alt_1_outlined,
                              label: 'Add',
                              tooltip:
                                  'Add customers to this and other salesman routes',
                              onPressed: _saving
                                  ? null
                                  : () => _addCustomersToSalesman(
                                      salesmanId: salesmanId,
                                      salesmanName:
                                          (salesman['name'] ?? 'Salesman')
                                              .toString(),
                                    ),
                            ),
                            _outlinedAction(
                              icon: Icons.print_outlined,
                              label: 'Print',
                              tooltip: 'Print assigned customers',
                              onPressed: () => _printAssignedCustomers(
                                salesmanName: (salesman['name'] ?? 'Salesman')
                                    .toString(),
                                routeName: assignedRouteName ?? '',
                                customers: routeCustomers,
                              ),
                            ),
                            _outlinedAction(
                              icon: Icons.delete_outline_rounded,
                              label: 'Remove',
                              tooltip: 'Remove active route assignment',
                              danger: !_saving,
                              onPressed: _saving
                                  ? null
                                  : () => _removeTodayAssignment(
                                      salesmanId: salesmanId,
                                      salesmanName:
                                          (salesman['name'] ?? 'Salesman')
                                              .toString(),
                                    ),
                            ),
                          ]),
                        ),
                      if (assignedIds.isEmpty)
                        const ListTile(
                          dense: true,
                          leading: Icon(Icons.info_outline_rounded),
                          title: Text(
                            'No assigned route to show customers from.',
                          ),
                        )
                      else if (routeCustomers.isEmpty)
                        const ListTile(
                          dense: true,
                          leading: Icon(Icons.people_outline_rounded),
                          title: Text(
                            'No customers found on this assigned route.',
                          ),
                        )
                      else ...[
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.people_outline_rounded),
                          title: Text(
                            "Today's customers (${routeCustomers.length})",
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: TextFormField(
                            key: ValueKey('customer-search-$salesmanId'),
                            initialValue: query,
                            textInputAction: TextInputAction.search,
                            decoration: const InputDecoration(
                              hintText: 'Search customer name or location',
                              prefixIcon: Icon(Icons.search_rounded),
                            ),
                            onChanged: (value) => setState(() {
                              _customerSearchBySalesman[salesmanId] = value
                                  .trim()
                                  .toLowerCase();
                            }),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: ['All', 'Pending', 'Visited'].map((
                              filter,
                            ) {
                              final count = searchedCustomers
                                  .where(
                                    (customer) =>
                                        matchesFilter(customer, filter),
                                  )
                                  .length;
                              return ChoiceChip(
                                label: Text('$filter ($count)'),
                                selected: customerFilter == filter,
                                onSelected: (_) => setState(() {
                                  _customerFiltersBySalesman[salesmanId] =
                                      filter;
                                }),
                              );
                            }).toList(),
                          ),
                        ),
                        if (visibleCustomers.isEmpty)
                          const ListTile(
                            title: Text(
                              'No customers match this search and filter.',
                            ),
                          ),
                        ...visibleCustomers.map((customer) {
                          final serialNumber =
                              customerSerialNumbers[customer.id];
                          final otherSalesmen =
                              _otherSalesmenAssignedToCustomer(
                                customer.id,
                                excludingSalesmanId: salesmanId,
                              );
                          final status =
                              _todayCustomerStatusesBySalesman[salesmanId]?[customer
                                  .id];
                          final statusLabel = switch (status) {
                            'paid' => 'Visited',
                            'rejected' => 'Refused today',
                            _ => 'Pending',
                          };
                          final statusColor = switch (statusLabel) {
                            'Visited' => Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            'Refused today' => Theme.of(
                              context,
                            ).colorScheme.error,
                            _ => Theme.of(context).colorScheme.tertiary,
                          };
                          final initials = customer.businessName
                              .trim()
                              .split(RegExp(r'\s+'))
                              .where((part) => part.isNotEmpty)
                              .take(2)
                              .map((part) => part[0].toUpperCase())
                              .join();
                          return ListTile(
                            contentPadding: const EdgeInsetsDirectional.only(
                              start: 16,
                              end: 16,
                            ),
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 32,
                                  child: Text(
                                    serialNumber == null
                                        ? ''
                                        : '$serialNumber.',
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                CircleAvatar(
                                  child: Text(
                                    initials.isEmpty ? '?' : initials,
                                  ),
                                ),
                              ],
                            ),
                            title: Text(
                              customer.businessName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  customer.location +
                                      (customer.phone.trim().isEmpty
                                          ? ''
                                          : ' • ${customer.phone}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  CurrencyFormatter.customerBalance(
                                    TransactionService.getCustomerBalance(
                                      customer.id,
                                    ),
                                  ),
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.09),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    statusLabel,
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (otherSalesmen.isNotEmpty)
                                  Text(
                                    'Also assigned to: ${otherSalesmen.join(', ')}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.secondary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Remove customer from this route',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _saving
                                      ? null
                                      : () => _removeCustomerFromSalesmanRoute(
                                          salesmanId: salesmanId,
                                          salesmanName:
                                              (salesman['name'] ?? 'Salesman')
                                                  .toString(),
                                          customer: customer,
                                        ),
                                  icon: Icon(
                                    Icons.person_remove_alt_1_outlined,
                                    color: Theme.of(context).colorScheme.error,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    CustomerDetailsScreen(customer: customer),
                              ),
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                );
              }),
        ],
      ],
    );
  }

  Widget _buildMapPage() {
    final colors = Theme.of(context).colorScheme;
    final phone = MediaQuery.sizeOf(context).width < 600;
    final route = _mapSalesmanId.isEmpty
        ? const <String>[]
        : (_todayCustomerAssignments[_mapSalesmanId] ?? const <String>[])
              .toSet()
              .toList();
    final statuses =
        _todayCustomerStatusesBySalesman[_mapSalesmanId] ??
        const <String, String>{};
    final stops = <CustomerStop>[];
    for (final row in _mapVisits) {
      final id = row['id'].toString();
      final at = route.indexOf(id);
      final stop = CustomerStop.fromRow(
        row,
        order: at < 0 ? null : at + 1,
        status: _mapSalesmanId.isEmpty
            ? row['status']?.toString() ?? ''
            : statuses[id] ?? '',
      );
      if (stop != null) stops.add(stop);
    }
    final salesmanIds = {
      for (final salesman in _salesmen) salesman['id'].toString(),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 20 : 24, 6, phone ? 20 : 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: salesmanIds.contains(_mapSalesmanId)
                      ? _mapSalesmanId
                      : '',
                  decoration: const InputDecoration(labelText: 'Show'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All customers'),
                    ),
                    for (final salesman in _salesmen)
                      DropdownMenuItem(
                        value: salesman['id'].toString(),
                        child: Text(
                          '${salesman['name'] ?? 'Salesman'}’s route',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _mapSalesmanId = value ?? ''),
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '${stops.length} of $_mapCustomerCount\non the map',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: CustomerMap(
              key: ValueKey('$_mapSalesmanId-${stops.length}'),
              stops: stops,
              emptyMessage:
                  'No customer locations are saved yet. A customer appears here after a payment, sale or refusal is recorded with location on.',
              onOpenCustomer: (stop) {
                for (final customer in CustomerService.customers) {
                  if (customer.id != stop.id) continue;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CustomerDetailsScreen(customer: customer),
                    ),
                  );
                  return;
                }
              },
            ),
          ),
          if (_mapVisitsLoading) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
