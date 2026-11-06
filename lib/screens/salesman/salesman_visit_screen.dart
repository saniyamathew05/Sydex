import 'package:flutter/material.dart';

import '../../models/customer.dart';
import '../../services/customer_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/salesman_visit_service.dart';
import '../../services/transaction_service.dart';
import 'salesman_customer_screen.dart';

/// Salesman's daily route and visit-status screen.
///
/// Route locations and visit outcomes are persisted through Supabase via
/// SalesmanVisitService. GPS capture is optional for visit outcomes.
class SalesmanVisitScreen extends StatefulWidget {
  const SalesmanVisitScreen({super.key});

  @override
  State<SalesmanVisitScreen> createState() => _SalesmanVisitScreenState();
}

class _SalesmanVisitScreenState extends State<SalesmanVisitScreen> {
  bool _loading = true;
  bool _savingRoute = false;
  String? _error;
  String? _routeName;
  List<String> _routeLocations = <String>[];
  List<String> _routeCustomerIds = <String>[];
  Map<String, String> _statuses = <String, String>{};
  final Set<String> _draftLocations = <String>{};
  final Set<String> _busyCustomerIds = <String>{};

  List<Customer> get _customers => CustomerService.customers;

  List<String> get _availableLocations {
    final values = _customers
        .map((customer) => customer.location.trim())
        .where((location) => location.isNotEmpty)
        .toSet()
        .toList();
    values.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return values;
  }

  List<Customer> get _routeCustomers {
    if (_routeCustomerIds.isEmpty) return <Customer>[];
    final customersById = {
      for (final customer in _customers) customer.id: customer,
    };
    return _routeCustomerIds
        .map((id) => customersById[id])
        .whereType<Customer>()
        .where(
          (customer) =>
              (TransactionService.customerBalances[customer.id] ??
                      customer.openingBalance) >
                  0 ||
              _statuses.containsKey(customer.id),
        )
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await CustomerService.loadCustomers();
      await TransactionService.loadTransactions();
      final values = await Future.wait<dynamic>([
        SalesmanVisitService.loadTodayRoute(),
        SalesmanVisitService.loadTodayCustomerIdsInOrder(),
        SalesmanVisitService.loadTodayStatuses(),
      ]);
      final routeLocations = List<String>.from(values[0] as List<String>);
      final routeCustomerIds = List<String>.from(values[1] as List<String>);
      String? routeName;
      try {
        routeName = await SalesmanVisitService.loadRouteNameForCustomerIds(
          routeCustomerIds,
          assignedLocations: routeLocations,
        );
      } catch (error) {
        debugPrint('Could not load assigned route name: $error');
      }
      if (!mounted) return;
      setState(() {
        _routeLocations = routeLocations;
        _routeName = routeName;
        _routeCustomerIds = routeCustomerIds;
        _statuses = Map<String, String>.from(values[2] as Map<String, String>);
        _draftLocations
          ..clear()
          ..addAll(_routeLocations);
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object error) {
    // Keep raw database/network details out of the interface.
    debugPrint('Salesman visit operation failed: $error');
    return 'We couldn’t load or save today’s route. Please check your connection and try again.';
  }

  Future<void> _saveRoute() async {
    setState(() {
      _savingRoute = true;
      _error = null;
    });
    try {
      await SalesmanVisitService.saveTodayRoute(_draftLocations.toList());
      await _refresh();
      if (mounted) _message('Today\'s route saved.');
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _savingRoute = false);
    }
  }

  Future<void> _recordOutcome(Customer customer, String status) async {
    if (_busyCustomerIds.contains(customer.id)) return;
    setState(() {
      _busyCustomerIds.add(customer.id);
      _error = null;
    });
    try {
      final locationSaved = await SalesmanVisitService.recordStatus(
        customerId: customer.id,
        status: status,
        note: status == 'rejected'
            ? 'No payment received during today\'s visit.'
            : null,
      );
      await _refresh();
      if (mounted) {
        _message(
          '${status == 'paid' ? 'Visit marked as payment received.' : 'Visit marked as no payment received.'}'
          '${locationSaved ? '' : ' Turn on location and allow access to add this customer to the map.'}',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busyCustomerIds.remove(customer.id));
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = _routeCustomers
        .where((customer) => _statuses.containsKey(customer.id))
        .length;
    final total = _routeCustomers.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today\'s visits'),
        actions: [
          IconButton(
            tooltip: 'Refresh visits',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    _ErrorBanner(message: _error!),
                    const SizedBox(height: 12),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _routeName ?? 'Daily route',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _routeName == null
                                ? 'Choose the customers you plan to visit today.'
                                : 'Your assigned customers for today are shown below.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 14),
                          if (_routeCustomerIds.isEmpty)
                            const Text('No customers are assigned for today.')
                          else
                            Text(
                              '${_routeCustomerIds.length} assigned customers will be shown below.',
                            ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _savingRoute ? null : _saveRoute,
                              icon: _savingRoute
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.route_rounded),
                              label: Text(
                                _savingRoute
                                    ? 'Saving route…'
                                    : 'Save today\'s route',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Visit progress',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                '$completed / $total',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: total == 0 ? 0 : completed / total,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Each customer can have one visit outcome recorded per day.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Customers on route',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_routeLocations.isEmpty)
                    const _EmptyState(
                      message:
                          'Choose one or more locations and save your route to see customers here.',
                    )
                  else if (_routeCustomers.isEmpty)
                    const _EmptyState(
                      message:
                          'There are no customers in the selected locations.',
                    )
                  else
                    ..._routeCustomers.map(_customerCard),
                ],
              ),
            ),
    );
  }

  Widget _customerCard(Customer customer) {
    final theme = Theme.of(context);
    final status = _statuses[customer.id];
    final busy = _busyCustomerIds.contains(customer.id);
    final completed = status == 'paid' || status == 'rejected';
    final statusLabel = status == 'paid'
        ? 'Payment received'
        : status == 'rejected'
        ? 'Refused today'
        : 'Not visited';
    final statusColor = status == 'paid'
        ? Colors.green
        : status == 'rejected'
        ? theme.colorScheme.error
        : theme.colorScheme.outline;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  child: Text(
                    customer.businessName.isEmpty
                        ? '?'
                        : customer.businessName[0].toUpperCase(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        customer.businessName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${customer.location}${customer.phone.trim().isEmpty ? '' : ' • ${customer.phone}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        CurrencyFormatter.customerBalance(
                          TransactionService.getCustomerBalance(customer.id),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  completed
                      ? Icons.check_circle_rounded
                      : Icons.pending_outlined,
                  color: statusColor,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Spacer(),
                if (!completed) ...[
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _recordOutcome(customer, 'rejected'),
                    child: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('No payment'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SalesmanCustomerDetailsScreen(
                                  customer: customer,
                                ),
                              ),
                            );
                            if (mounted) await _refresh();
                          },
                    child: const Text('Open customer'),
                  ),
                ],
              ],
            ),
            if (completed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'This customer already has a visit outcome recorded today.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Center(child: Text(message, textAlign: TextAlign.center)),
    ),
  );
}
