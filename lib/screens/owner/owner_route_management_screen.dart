import 'dart:convert';
import 'dart:io';

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
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<Map<String, dynamic>> _routes = [];
  List<Map<String, dynamic>> _salesmen = [];
  final Map<String, List<String>> _todayAssignments = {};
  final Map<String, List<String>> _todayCustomerAssignments = {};
  Map<String, String> _todayCustomerStatuses = {};
  final Map<String, String> _customerFiltersBySalesman = {};
  final Map<String, String> _customerSearchBySalesman = {};
  String _salesmanFilterId = '';
  String? _selectedRouteId;
  final Set<String> _selectedSalesmanIds = {};
  Set<String> _selectedCustomerIds = {};

  Map<String, dynamic>? get _selectedRoute {
    for (final route in _routes) {
      if (route['id'].toString() == _selectedRouteId) return route;
    }
    return null;
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _routeNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await CustomerService.loadCustomers();
      await TransactionService.loadCustomerBalances();
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      List<Map<String, dynamic>> routeRows;
      try {
        final rows = await _client
            .from('salesman_route_templates')
            .select('id, route_name, locations, customer_ids, updated_at')
            .order('route_name');
        routeRows = List<Map<String, dynamic>>.from(rows);
      } catch (error) {
        // Keep existing routes usable until the optional customer_ids migration
        // has been applied in Supabase.
        debugPrint('Customer-level route column unavailable: $error');
        final rows = await _client
            .from('salesman_route_templates')
            .select('id, route_name, locations, updated_at')
            .order('route_name');
        routeRows = List<Map<String, dynamic>>.from(rows);
      }
      final results = await Future.wait<dynamic>([
        Future.value(routeRows),
        _client.from('profiles').select('id, name, role').order('name'),
        _client
            .from('salesman_daily_route_selections')
            .select('salesman_id, locations, customer_ids, route_date')
            .lte('route_date', todayKey)
            .order('route_date', ascending: false),
        SalesmanVisitService.loadTodayStatusesForOwner(),
      ]);
      final allProfiles = List<Map<String, dynamic>>.from(results[1] as List);
      final assignmentRows = List<Map<String, dynamic>>.from(
        results[2] as List,
      );
      final todayStatuses = Map<String, String>.from(
        results[3] as Map<String, String>,
      );
      final assignments = <String, List<String>>{};
      final customerAssignments = <String, List<String>>{};
      for (final row in assignmentRows) {
        final id = (row['salesman_id'] ?? '').toString();
        final rawLocations = row['locations'];
        if (id.isNotEmpty &&
            rawLocations is List &&
            !assignments.containsKey(id)) {
          assignments[id] = rawLocations.map((e) => e.toString()).toList();
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
        if (id.isNotEmpty && parsedCustomerIds.isNotEmpty) {
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
        _routes = List<Map<String, dynamic>>.from(results[0] as List);
        _salesmen = salesmen;
        _todayAssignments
          ..clear()
          ..addAll(assignments);
        _todayCustomerAssignments
          ..clear()
          ..addAll(customerAssignments);
        _todayCustomerStatuses = todayStatuses;
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
        _selectedCustomerIds = _selectedRoute == null
            ? <String>{}
            : Set<String>.from(
                ((_selectedRoute!['customer_ids'] as List?) ?? const []).map(
                  (e) => e.toString(),
                ),
              );
        _loading = false;
      });
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

  Future<void> _createRoute() async {
    final name = _routeNameController.text.trim();
    if (name.isEmpty) {
      _message('Enter a route name first.');
      return;
    }
    setState(() => _saving = true);
    try {
      final row = await _client
          .from('salesman_route_templates')
          .insert({'route_name': name, 'locations': <String>[]})
          .select('id, route_name, locations, updated_at')
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
        _selectedCustomerIds = <String>{};
        _routeNameController.clear();
      });
      _message('Route created. Select its locations below.');
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
        name.trim() == route['route_name'])
      return;
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
    if (route == null) return;
    setState(() => _saving = true);
    try {
      if (_selectedCustomerIds.isEmpty) {
        _message('Select at least one customer first.');
        return;
      }
      final locations = _locationsForSelectedCustomers();
      await _client
          .from('salesman_route_templates')
          .update({
            'locations': locations,
            'customer_ids': _selectedCustomerIds.toList(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', route['id'].toString());
      if (!mounted) return;
      setState(() {
        final index = _routes.indexWhere(
          (r) => r['id'].toString() == route['id'].toString(),
        );
        if (index >= 0)
          _routes[index] = {
            ..._routes[index],
            'locations': locations,
            'customer_ids': _selectedCustomerIds.toList(),
          };
      });
      _message('Default locations saved for ${route['route_name']}.');
    } catch (error) {
      debugPrint('Save route locations failed: $error');
      _message('Could not save these locations. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectRouteCustomers() async {
    final eligible =
        CustomerService.customers
            .where(
              (customer) =>
                  // A route should only be assigned from customers who
                  // currently owe money. A customer whose balance reaches
                  // zero after today's payment remains visible to the
                  // salesman through today's visit/status record.
                  TransactionService.getCustomerBalance(customer.id) > 0 &&
                  true,
            )
            .toList()
          ..sort(
            (a, b) => a.businessName.toLowerCase().compareTo(
              b.businessName.toLowerCase(),
            ),
          );
    // Each time the picker opens, start a fresh selection. This prevents an
    // old location-based assignment from silently carrying dozens of IDs into
    // the new customer-only route.
    final selected = <String>{};
    var searchQuery = '';
    await showDialog<void>(
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
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            content: SizedBox(
              width: MediaQuery.sizeOf(context).width * 0.82,
              height: MediaQuery.sizeOf(context).height * 0.68,
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Select only the customers this route should include. '
                      'Only customers you select here will be assigned and shown to salesmen.',
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
                  if (eligible.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'No customers with a pending balance found.',
                        ),
                      ),
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
                        children: filteredEligible
                            .map(
                              (customer) => CheckboxListTile(
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
                                  ],
                                ),
                                onChanged: (checked) => setDialogState(() {
                                  if (checked == true) {
                                    selected.add(customer.id);
                                  } else {
                                    selected.remove(customer.id);
                                  }
                                }),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: eligible.isEmpty
                    ? null
                    : () => setDialogState(() => selected.clear()),
                child: const Text('Clear selected'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() => _selectedCustomerIds = selected);
                  Navigator.pop(dialogContext);
                },
                child: const Text('Save selection'),
              ),
            ],
          );
        },
      ),
    );
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
    final assignmentLocations = _locationsForSelectedCustomers().toSet();
    setState(() => _saving = true);
    try {
      final today = DateTime.now();
      final dateKey =
          '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final locations = _locationsForSelectedCustomers();
      // The latest dated assignment remains active until the owner removes it.
      // Keep the saved named route in sync so salesmen can display its name.
      await _client
          .from('salesman_route_templates')
          .update({
            'locations': locations,
            'customer_ids': _selectedCustomerIds.toList(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', route['id'].toString());
      final assignments = salesmanIds
          .map(
            (salesmanId) => {
              'salesman_id': salesmanId,
              'route_date': dateKey,
              'locations': locations,
              'customer_ids': _selectedCustomerIds.toList(),
            },
          )
          .toList();
      await _client
          .from('salesman_daily_route_selections')
          .upsert(assignments, onConflict: 'salesman_id,route_date');
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
        for (final salesmanId in salesmanIds) {
          _todayAssignments[salesmanId] = locations;
          _todayCustomerAssignments[salesmanId] = List<String>.from(
            _selectedCustomerIds,
          );
        }
      });
      _message(
        'Route assigned to ${salesmanIds.length} salesman'
        '${salesmanIds.length == 1 ? '' : 's'}.',
      );
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
      final today = DateTime.now();
      final dateKey =
          '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      // Store an empty assignment for today instead of deleting the last row.
      // This prevents an older assignment from becoming active again tomorrow.
      await _client.from('salesman_daily_route_selections').upsert({
        'salesman_id': salesmanId,
        'route_date': dateKey,
        'locations': <String>[],
        'customer_ids': <String>[],
      }, onConflict: 'salesman_id,route_date');
      await _client
          .from('salesman_customer_daily_status')
          .delete()
          .eq('entered_by', salesmanId);
      if (!mounted) return;
      setState(() {
        _todayAssignments[salesmanId] = <String>[];
        _todayCustomerAssignments[salesmanId] = <String>[];
      });
      _message('Route assignment removed for $salesmanName.');
    } catch (error) {
      debugPrint('Remove daily route failed: $error');
      _message('Could not remove today’s route. Please try again.');
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
          pw.Table.fromTextArray(
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
      appBar: AppBar(
        title: Text(switch (widget.page) {
          OwnerRoutePage.places => 'Places & Routes',
          OwnerRoutePage.salesmen => 'Salesmen & Assigned Routes',
          OwnerRoutePage.map => 'Route Map View',
        }),
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
          ? ListView(
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 12 : 20,
              ),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Create a reusable route',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 420;
                            final routeNameField = TextField(
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
                            final createButton = FilledButton.icon(
                              onPressed: _saving ? null : _createRoute,
                              icon: const Icon(Icons.add_road_rounded),
                              label: const Text('Create route'),
                            );
                            if (compact) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  routeNameField,
                                  const SizedBox(height: 10),
                                  createButton,
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(child: routeNameField),
                                const SizedBox(width: 10),
                                createButton,
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Set up who to visit',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'First choose the areas, then choose whether to visit everyone there or only selected customers.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 14),
                        if (_routes.isEmpty)
                          const Text('Create your first route to get started.')
                        else
                          DropdownButtonFormField<String>(
                            value: _selectedRouteId,
                            decoration: const InputDecoration(
                              labelText: 'Saved route',
                            ),
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
                            onChanged: (id) {
                              setState(() {
                                _selectedRouteId = id;
                                _selectedSalesmanIds.clear();
                                _selectedCustomerIds = _selectedRoute == null
                                    ? <String>{}
                                    : Set<String>.from(
                                        ((_selectedRoute!['customer_ids']
                                                    as List?) ??
                                                const [])
                                            .map((value) => value.toString()),
                                      );
                              });
                            },
                          ),
                        const SizedBox(height: 18),
                        Text(
                          'Choose customers for this route',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Select the customers to visit. Only these selected customers will appear for the owner and salesman.',
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.people_alt_outlined),
                          title: Text(
                            _selectedCustomerIds.isEmpty
                                ? 'No customers selected'
                                : '${_selectedCustomerIds.length} customers selected',
                          ),
                          subtitle: const Text(
                            'Customers with a pending balance are available to select.',
                          ),
                          trailing: OutlinedButton(
                            onPressed: _selectedRoute == null
                                ? null
                                : _selectRouteCustomers,
                            child: Text(
                              _selectedCustomerIds.isEmpty
                                  ? 'Choose'
                                  : 'Change',
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  _saving ||
                                      _selectedRoute == null ||
                                      _selectedCustomerIds.isEmpty
                                  ? null
                                  : _saveTemplateLocations,
                              icon: const Icon(Icons.save_outlined),
                              label: Text('Save customer selection'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _saving || _selectedRoute == null
                                  ? null
                                  : _renameRoute,
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Rename route'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _saving || _selectedRoute == null
                                  ? null
                                  : _deleteRoute,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Delete route'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Divider(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Assign route to salesmen',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Select one or more salesmen. The route stays assigned until you remove it from Salesmen & Assigned Routes. Assignments use the selected customers above.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        ..._salesmen.map((salesman) {
                          final salesmanId = salesman['id'].toString();
                          final currentLocations =
                              _todayAssignments[salesmanId];
                          final subtitle = currentLocations == null
                              ? 'No active route assignment'
                              : currentLocations.isEmpty
                              ? 'No active route assignment'
                              : 'Location order: ${currentLocations.join(' → ')}';
                          return CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _selectedSalesmanIds.contains(salesmanId),
                            title: Text(
                              (salesman['name'] ?? 'Salesman').toString(),
                            ),
                            subtitle: Text(subtitle),
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
                        }),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed:
                              _saving ||
                                  _selectedRoute == null ||
                                  _selectedSalesmanIds.isEmpty ||
                                  _selectedCustomerIds.isEmpty
                              ? null
                              : _assignForToday,
                          icon: const Icon(Icons.route_outlined),
                          label: const Text(
                            'Assign route to selected salesmen',
                          ),
                        ),
                        if (_salesmen.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'No salesman accounts were found. Add a user with the Salesman role first.',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : widget.page == OwnerRoutePage.salesmen
          ? _buildSalesmenPage()
          : _buildMapPage(),
    );
  }

  Widget _buildSalesmenPage() {
    return ListView(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 12 : 20),
      children: [
        const Text(
          'Salesmen and their assigned routes',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Assignments stay active until you remove them. Open Places & Routes to create or edit a named route and assign it.',
        ),
        const SizedBox(height: 12),
        if (_salesmen.isEmpty)
          const Text('No salesman accounts were found.')
        else ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Salesman'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _salesmanFilterId,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('All salesmen'),
                      ),
                      ..._salesmen.map(
                        (salesman) => DropdownMenuItem(
                          value: salesman['id'].toString(),
                          child: Text(
                            (salesman['name'] ?? 'Salesman').toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      _salesmanFilterId = value ?? '';
                    }),
                  ),
                ),
              ),
            ),
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
                final assignedIds =
                    _todayCustomerAssignments[salesmanId] ?? const <String>[];
                final subtitle = assignedIds.isEmpty
                    ? 'No active route assignment'
                    : '${assignedRouteName == null ? 'Assigned customers' : 'Route: $assignedRouteName'}\n${assignedIds.length} selected customers';
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
                  final visited = _todayCustomerStatuses.containsKey(
                    customer.id,
                  );
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
                        leading: const CircleAvatar(
                          child: Icon(Icons.person_outline),
                        ),
                        title: Text(
                          (salesman['name'] ?? 'Salesman').toString(),
                        ),
                        subtitle: Text(subtitle),
                        trailing: assignedIds.isEmpty
                            ? null
                            : Wrap(
                                spacing: 2,
                                children: [
                                  IconButton(
                                    tooltip: 'Print assigned customers',
                                    onPressed: () => _printAssignedCustomers(
                                      salesmanName:
                                          (salesman['name'] ?? 'Salesman')
                                              .toString(),
                                      routeName: assignedRouteName ?? '',
                                      customers: routeCustomers,
                                    ),
                                    icon: const Icon(Icons.print_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove active route assignment',
                                    onPressed: _saving
                                        ? null
                                        : () => _removeTodayAssignment(
                                            salesmanId: salesmanId,
                                            salesmanName:
                                                (salesman['name'] ?? 'Salesman')
                                                    .toString(),
                                          ),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                  ),
                                ],
                              ),
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
                          final status = _todayCustomerStatuses[customer.id];
                          final statusLabel = switch (status) {
                            'paid' => 'Visited',
                            'rejected' => 'Refused today',
                            _ => 'Pending',
                          };
                          final statusColor = switch (statusLabel) {
                            'Visited' => const Color(0xFF27845B),
                            'Refused today' => const Color(0xFFD64A55),
                            _ => const Color(0xFFD58B28),
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
                              start: 56,
                              end: 16,
                            ),
                            leading: CircleAvatar(
                              child: Text(initials.isEmpty ? '?' : initials),
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
                              ],
                            ),
                            trailing: Container(
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
    return ListView(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 12 : 20),
      children: [
        const Text(
          'Saved route locations',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Review the locations saved under each route. Places & Routes is where you can edit them.',
        ),
        const SizedBox(height: 12),
        if (_routes.isEmpty)
          const Text('No routes created yet.')
        else
          ..._routes.map((route) {
            final locations = (route['locations'] as List? ?? const [])
                .map((e) => e.toString())
                .toList();
            return Card(
              child: ListTile(
                leading: const Icon(Icons.map_outlined),
                title: Text(route['route_name'].toString()),
                subtitle: Text(
                  locations.isEmpty
                      ? 'No locations added'
                      : locations.join(' → '),
                ),
              ),
            );
          }),
      ],
    );
  }
}
