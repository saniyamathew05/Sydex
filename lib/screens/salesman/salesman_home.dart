import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr/qr.dart';

import '../../models/customer.dart';
import '../../models/transaction.dart';

import '../payments/payment_screen.dart';

import 'salesman_customer_screen.dart';

import 'salesman_payments_screen.dart';

import '../../services/customer_service.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';

import '../../services/salesman_visit_service.dart';
import '../../services/tutorial_service.dart';
import '../settings/tutorial_screen.dart';

import '../settings/settings_screen.dart';

class SalesmanHome extends StatefulWidget {
  final String userName;

  const SalesmanHome({super.key, required this.userName});

  @override
  State<SalesmanHome> createState() => _SalesmanHomeState();
}

class _SalesmanHomeState extends State<SalesmanHome> {
  final TextEditingController searchController = TextEditingController();

  final SupabaseClient supabase = Supabase.instance.client;

  int selectedIndex = 0;

  String customerStatusFilter = 'All';

  bool isLoading = true;

  List<String> selectedRouteLocations = <String>[];
  List<String> selectedRouteCustomerIds = <String>[];

  String? selectedRouteName;

  Map<String, String> todaysCustomerStatuses = <String, String>{};

  Timer? _presenceTimer;

  RealtimeChannel? _forceLogoutChannel;

  bool _presenceCheckRunning = false;

  bool _forcedLogoutInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showTutorialIfNeeded(),
    );

    _loadData();

    _startPresenceMonitoring();

    _startForceLogoutListener();
  }

  void _startPresenceMonitoring() {
    _checkPresence();

    _presenceTimer = Timer.periodic(
      const Duration(seconds: 15),

      (_) => _checkPresence(),
    );
  }

  void _startForceLogoutListener() {
    final userId = supabase.auth.currentUser?.id;

    if (userId == null) return;

    _forceLogoutChannel?.unsubscribe();

    _forceLogoutChannel = supabase
        .channel('salesman-force-logout-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,

          schema: 'public',

          table: 'profiles',

          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,

            column: 'id',

            value: userId,
          ),

          callback: (payload) {
            final forceLogoutAt = payload.newRecord['force_logout_at'];

            if (forceLogoutAt != null && !_forcedLogoutInProgress) {
              _handleForceLogout();
            }
          },
        )
        .subscribe();
  }

  Future<void> _handleForceLogout() async {
    if (_forcedLogoutInProgress) return;

    _forcedLogoutInProgress = true;

    _presenceTimer?.cancel();

    try {
      await supabase.auth.signOut();
    } catch (_) {
      // Continue to the login screen even if sign-out reports an error.
    }

    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  Future<void> _checkPresence() async {
    if (!mounted || _presenceCheckRunning || _forcedLogoutInProgress) return;

    final user = supabase.auth.currentUser;

    if (user == null) return;

    _presenceCheckRunning = true;

    try {
      await supabase.rpc('salesman_heartbeat');

      final profile = await supabase
          .from('profiles')
          .select('force_logout_at')
          .eq('id', user.id)
          .maybeSingle();

      final forceLogoutAt = profile?['force_logout_at'];

      if (forceLogoutAt != null && mounted) {
        await _handleForceLogout();
      }
    } catch (_) {
      // Presence must never interrupt the existing salesman features.
    } finally {
      _presenceCheckRunning = false;
    }
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        isLoading = true;
      });
    }

    await CustomerService.loadCustomers();

    await TransactionService.loadTransactions();

    try {
      selectedRouteLocations = await SalesmanVisitService.loadTodayRoute();
      selectedRouteCustomerIds =
          await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      try {
        selectedRouteName =
            await SalesmanVisitService.loadRouteNameForCustomerIds(
              selectedRouteCustomerIds,
              assignedLocations: selectedRouteLocations,
            );
      } catch (error) {
        selectedRouteName = null;
        debugPrint('Could not load route name: $error');
      }

      todaysCustomerStatuses = await SalesmanVisitService.loadTodayStatuses();
    } catch (error) {
      debugPrint('Could not load route/status data: $error');
    }

    // Payment history is already loaded above. Use today's received entries
    // as a visited signal even if the separate visit-status query is blocked
    // by an older RLS policy or an expired session.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final transaction in TransactionService.transactions) {
      final date = transaction.transactionDate.toLocal();
      final transactionDay = DateTime(date.year, date.month, date.day);
      if (transactionDay == today && _isCurrentUsersPayment(transaction)) {
        // Keep an explicit visit outcome authoritative. A payment saved by
        // another executive must never alter this executive's route progress.
        todaysCustomerStatuses.putIfAbsent(
          transaction.customerId,
          () => 'paid',
        );
      }
    }

    if (!mounted) return;

    setState(() {
      isLoading = false;
    });
  }

  List<Customer> get routeCustomers {
    if (selectedRouteCustomerIds.isEmpty) return <Customer>[];

    final customersById = {
      for (final customer in CustomerService.customers) customer.id: customer,
    };
    // The owner-selected assignment is the source of truth. A customer
    // stays on today's route even when their balance is zero or they have not
    // yet been visited, so the assigned count and route order remain stable.
    return selectedRouteCustomerIds
        .map((id) => customersById[id])
        .whereType<Customer>()
        .toList(growable: false);
  }

  List<Customer> get filteredCustomers {
    final query = searchController.text.trim().toLowerCase();

    return routeCustomers.where((customer) {
      final matchesSearch =
          query.isEmpty ||
          customer.businessName.toLowerCase().contains(query) ||
          customer.location.toLowerCase().contains(query) ||
          customer.phone.contains(query);
      final status = todaysCustomerStatuses[customer.id];
      final matchesStatus = switch (customerStatusFilter) {
        'Pending' => !_isVisitCompleted(status),
        'Visited' => _isVisitCompleted(status),
        _ => true,
      };
      return matchesSearch && matchesStatus;
    }).toList();
  }

  int _statusCount(String filter) {
    return routeCustomers.where((customer) {
      final status = todaysCustomerStatuses[customer.id];
      return switch (filter) {
        'Pending' => !_isVisitCompleted(status),
        'Visited' => _isVisitCompleted(status),
        _ => true,
      };
    }).length;
  }

  String _statusLabel(Customer customer) {
    final status = todaysCustomerStatuses[customer.id];
    if (status == 'paid') return 'Visited';
    if (status == 'rejected') return 'Refused today';
    return 'Pending';
  }

  bool _isVisitCompleted(String? status) =>
      status == 'paid' || status == 'rejected';

  bool _isToday(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    return local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
  }

  bool _isCurrentUsersPayment(PaymentTransaction transaction) {
    final userId = supabase.auth.currentUser?.id;
    // Legacy rows can lack an entry user. They remain visible rather than
    // disappearing, while new rows are scoped to the collector who saved them.
    return transaction.enteredBy == null || transaction.enteredBy == userId;
  }

  double _collectedToday() => TransactionService.transactions
      .where(
        (transaction) =>
            transaction.transactionType == 'payment_received' &&
            !transaction.isBounced &&
            transaction.actualAmountReceived > 0 &&
            _isToday(transaction.transactionDate) &&
            _isCurrentUsersPayment(transaction),
      )
      .fold<double>(
        0,
        (sum, transaction) => sum + transaction.actualAmountReceived,
      );

  int _paymentsToday() => TransactionService.transactions
      .where(
        (transaction) =>
            transaction.transactionType == 'payment_received' &&
            !transaction.isBounced &&
            transaction.actualAmountReceived > 0 &&
            _isToday(transaction.transactionDate) &&
            _isCurrentUsersPayment(transaction),
      )
      .length;

  double _pendingCollection(List<Customer> customers) {
    return customers.fold<double>(0, (total, customer) {
      final balance = TransactionService.getCustomerBalance(customer.id);
      return total + (balance > 0 ? balance : 0);
    });
  }

  Future<void> _chooseTodayRoute() async {
    // Routes are assigned by the owner in Places & Routes. Salesmen must not
    // be able to broaden their own route beyond the owner's daily assignment.
    try {
      final assigned = await SalesmanVisitService.loadTodayRoute();
      final assignedCustomerIds =
          await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      String? routeName;
      try {
        routeName = await SalesmanVisitService.loadRouteNameForCustomerIds(
          assignedCustomerIds,
          assignedLocations: assigned,
        );
      } catch (error) {
        debugPrint('Could not load route name: $error');
      }
      if (!mounted) return;
      setState(() {
        selectedRouteLocations = assigned;
        selectedRouteCustomerIds = assignedCustomerIds;
        selectedRouteName = routeName;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            assigned.isEmpty
                ? 'No route has been assigned by the owner for today.'
                : 'Loaded the locations assigned by the owner.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load the assigned route. Please try again.'),
        ),
      );
    }
  }

  Future<void> _startRoute() async {
    try {
      final assigned = await SalesmanVisitService.loadTodayRoute();
      if (assigned.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No route has been assigned for today.'),
          ),
        );
        return;
      }

      final assignedCustomerIds =
          await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      String? routeName;
      try {
        routeName = await SalesmanVisitService.loadRouteNameForCustomerIds(
          assignedCustomerIds,
          assignedLocations: assigned,
        );
      } catch (error) {
        debugPrint('Could not load route name: $error');
      }
      if (!mounted) return;
      setState(() {
        selectedRouteLocations = assigned;
        selectedRouteCustomerIds = assignedCustomerIds;
        selectedRouteName = routeName;
        selectedIndex = 1;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load the assigned route. Please try again.'),
        ),
      );
    }
  }

  Future<void> _finishRoute() async {
    if (routeCustomers.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finish current route?'),
        content: const Text(
          'Your recorded visits and refused customers will remain saved. If the owner has queued another route, it will become active next.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Finish route'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final outcome = await SalesmanVisitService.finishCurrentRoute();
      if (!mounted) return;
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome == 'next_route_activated'
                ? 'Route finished. Your next assigned route is ready.'
                : 'Route finished. No queued route is waiting.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not finish the route. Please try again.'),
        ),
      );
    }
  }

  Future<void> _openCustomer(Customer customer) async {
    try {
      todaysCustomerStatuses = await SalesmanVisitService.loadTodayStatuses();
      if (mounted) setState(() {});
    } catch (error) {
      debugPrint('Could not refresh customer visit status: $error');
    }
    if (!mounted) return;

    await Navigator.push(
      context,

      MaterialPageRoute(
        builder: (_) => SalesmanCustomerDetailsScreen(customer: customer),
      ),
    );

    await _loadData();
  }

  Future<void> _openPaymentScreen(Customer customer) async {
    final result = await Navigator.push<bool>(
      context,

      MaterialPageRoute(builder: (_) => PaymentScreen(customer: customer)),
    );

    if (result == true) {
      try {
        final locationSaved = await SalesmanVisitService.recordStatus(
          customerId: customer.id,
          status: 'paid',
        );
        todaysCustomerStatuses[customer.id] = 'paid';
        if (!locationSaved && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Payment saved. Turn on location and allow access to add this customer to the map.',
              ),
            ),
          );
        }
      } catch (error) {
        debugPrint('Could not record payment visit status: $error');
      }
    }

    await TransactionService.loadTransactions();

    if (mounted) setState(() {});

    await _loadData();
  }

  void _openPayments() {
    Navigator.push(
      context,

      MaterialPageRoute(builder: (_) => const SalesmanPaymentsScreen()),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,

      MaterialPageRoute(
        builder: (_) =>
            SettingsScreen(role: 'salesman', userName: widget.userName),
      ),
    );
  }

  Future<void> _showPaymentQr() async {
    List<String> upiIds = <String>[];
    var netBankingQr = '';
    try {
      final row = await supabase
          .from('payment_settings')
          .select('upi_id, net_banking_qr')
          .eq('id', 1)
          .maybeSingle();
      upiIds = (row?['upi_id']?.toString() ?? '')
          .split(RegExp(r'[\n,;]+'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      netBankingQr = row?['net_banking_qr']?.toString().trim() ?? '';
    } catch (_) {}
    if (!mounted) return;
    if (upiIds.isEmpty && netBankingQr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The owner has not configured the business UPI ID yet.',
          ),
        ),
      );
      return;
    }
    var upi = upiIds.isEmpty ? '' : upiIds.first;
    var payload = upi.isEmpty
        ? netBankingQr
        : 'upi://pay?pa=${Uri.encodeComponent(upi)}&pn=${Uri.encodeComponent('Horizon')}';
    var qrLabel = upi.isEmpty ? 'Net banking' : upi;
    if (upiIds.length > 1 || (upiIds.isNotEmpty && netBankingQr.isNotEmpty)) {
      final selected = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Choose payment account'),
          children: [
            ...upiIds.map(
              (id) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, id),
                child: Text(id),
              ),
            ),
            if (netBankingQr.isNotEmpty)
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(dialogContext, '__net_banking__'),
                child: const Text('Net banking'),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      if (selected == '__net_banking__') {
        payload = netBankingQr;
        qrLabel = 'Net banking';
      } else {
        upi = selected;
        payload =
            'upi://pay?pa=${Uri.encodeComponent(upi)}&pn=${Uri.encodeComponent('Horizon')}';
        qrLabel = upi;
      }
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Receive payment by QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Show this QR code to the customer.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              color: Colors.white,
              child: SizedBox(
                width: 220,
                height: 220,
                child: CustomPaint(painter: _PaymentQrPainter(payload)),
              ),
            ),
            const SizedBox(height: 12),
            Text(qrLabel, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (upi.isNotEmpty) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: upi));
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(content: Text('UPI ID copied.')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy UPI ID'),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Confirm the payment before recording it in Horizon.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,

      builder: (context) {
        return AlertDialog(
          title: const Text('Log out?'),

          content: const Text(
            'Are you sure you want to log out of this account?',
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
              },

              child: const Text('Cancel'),
            ),

            FilledButton(
              onPressed: () {
                Navigator.pop(context, true);
              },

              child: const Text('Log out'),
            ),
          ],
        );
      },
    );

    if (shouldLogout != true) return;

    await supabase.auth.signOut();

    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  Widget _buildHomeTab() {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final route = routeCustomers;
    final visited = route
        .where((c) => _isVisitCompleted(todaysCustomerStatuses[c.id]))
        .length;
    final paid = route
        .where((c) => todaysCustomerStatuses[c.id] == 'paid')
        .length;
    final noPayment = route
        .where((c) => todaysCustomerStatuses[c.id] == 'rejected')
        .length;
    final pending = route
        .where((c) => !_isVisitCompleted(todaysCustomerStatuses[c.id]))
        .length;
    final collectedToday = _collectedToday();
    final paymentCount = _paymentsToday();
    final pendingCollection = _pendingCollection(route);
    final recentPayments = TransactionService.transactions
        .where(
          (transaction) =>
              transaction.transactionType == 'payment_received' &&
              !transaction.isBounced &&
              transaction.actualAmountReceived > 0 &&
              _isToday(transaction.transactionDate) &&
              _isCurrentUsersPayment(transaction),
        )
        .take(4)
        .toList(growable: false);
    final green = colors.primary;
    final emerald = colors.primary;
    final ink = Theme.of(context).colorScheme.onSurface;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_getGreeting()},',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 21,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                  ],
                ),
              ),
              CircleAvatar(
                radius: 18,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: Text(
                  _getInitials(widget.userName),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _SalesmanStatusCard(
                  icon: Icons.account_balance_wallet_rounded,
                  label: '$paymentCount payments today',
                  value: CurrencyFormatter.rupees(collectedToday),
                  color: emerald,
                  background: isDark
                      ? const Color(0xFF173A35)
                      : const Color(0xFFEAF8F2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SalesmanStatusCard(
                  icon: Icons.check_circle_rounded,
                  label: 'Visits completed',
                  value: '$visited',
                  color: const Color(0xFFE5A12B),
                  background: isDark
                      ? const Color(0xFF3B3020)
                      : const Color(0xFFFFF5E6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _SalesmanStatusCard(
                  icon: Icons.groups_rounded,
                  label: 'Pending visits',
                  value: '$pending',
                  color: const Color(0xFFE5A12B),
                  background: isDark
                      ? const Color(0xFF40252D)
                      : const Color(0xFFFFEFF0),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SalesmanStatusCard(
                  icon: Icons.stacked_bar_chart_rounded,
                  label: 'Pending collection',
                  value: CurrencyFormatter.rupees(pendingCollection),
                  color: const Color(0xFFC83B32),
                  background: isDark
                      ? const Color(0xFF183D2D)
                      : const Color(0xFFEAF3EC),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.insights_rounded,
                      size: 18,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Today’s visit progress',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    Text(
                      '$visited / ${route.length}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: colors.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: route.isEmpty ? 0 : visited / route.length,
                    minHeight: 8,
                    backgroundColor: colors.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  route.isEmpty
                      ? 'No customers are assigned today.'
                      : '$pending customers remaining',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (route.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _finishRoute,
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: const Text('Finish route'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (noPayment > 0)
            Text(
              '$noPayment refused today · $paid payments recorded',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recent Payments',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              TextButton(
                onPressed: _openPayments,
                child: Text(
                  'View all',
                  style: TextStyle(color: green, fontSize: 12),
                ),
              ),
            ],
          ),
          if (recentPayments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'No payments received yet',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            )
          else
            ...recentPayments.map(
              (transaction) => _PaymentPreviewCard(
                customerName: transaction.customerName,
                amount: transaction.actualAmountReceived,
                date: _formatDate(transaction.transactionDate),
                onTap: _openPayments,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCustomersTab() {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = colors.onSurface;
    final filters = ['All', 'Pending', 'Visited'];

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to home',
                  onPressed: () => setState(() => selectedIndex = 0),
                  icon: const Icon(Icons.arrow_back_rounded, size: 21),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    "Today's Customers",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.45,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: TextField(
              controller: searchController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search customer...',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: colors.onSurfaceVariant,
                ),
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
                suffixIcon: searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 12,
                ),
                filled: true,
                fillColor: colors.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(13),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(13),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(13),
                  borderSide: BorderSide(color: colors.primary, width: 1.2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 9),
            child: Row(
              children: filters.map((filter) {
                final selected = customerStatusFilter == filter;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: filter == filters.last ? 0 : 7,
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () =>
                          setState(() => customerStatusFilter = filter),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 5,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? colors.primary
                              : colors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? colors.primary
                                : colors.outlineVariant,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '$filter (${_statusCount(filter)})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected ? Colors.white : colors.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          Expanded(
            child: filteredCustomers.isEmpty
                ? RefreshIndicator(
                    onRefresh: _loadData,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 65),
                      children: [
                        Icon(
                          Icons.people_outline_rounded,
                          size: 42,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            searchController.text.trim().isNotEmpty
                                ? 'No matching customers'
                                : 'No customers in this filter',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadData,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 3, 20, 18),
                      itemCount: filteredCustomers.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 0.6,
                        indent: 47,
                        color: colors.outlineVariant,
                      ),
                      itemBuilder: (context, index) {
                        final customer = filteredCustomers[index];
                        final status = _statusLabel(customer);
                        final statusColor = switch (status) {
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
                        final avatarColors = isDark
                            ? const [
                                Color(0xFF155A3A),
                                Color(0xFF1E6544),
                                Color(0xFF25513B),
                                Color(0xFF214B45),
                              ]
                            : const [
                                Color(0xFFDDF3E5),
                                Color(0xFFC9E5D1),
                                Color(0xFFEAF3EC),
                                Color(0xFFD9F0EB),
                              ];
                        return InkWell(
                          onTap: () => _openCustomer(customer),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 1,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 35,
                                  height: 35,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color:
                                        avatarColors[index %
                                            avatarColors.length],
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    initials.isEmpty ? '?' : initials,
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFFDDF3E5)
                                          : colors.primary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        customer.businessName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: ink,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (status == 'Refused today') ...[
                                        const SizedBox(height: 3),
                                        const Row(
                                          children: [
                                            Icon(
                                              Icons.block_rounded,
                                              size: 11,
                                              color: Color(0xFFD64A55),
                                            ),
                                            SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                'Already refused today — do not ask again',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Color(0xFFD64A55),
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.location_on_outlined,
                                            size: 11,
                                            color: colors.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 2),
                                          Expanded(
                                            child: Text(
                                              customer.location,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: colors.onSurfaceVariant,
                                                fontSize: 10.5,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            CurrencyFormatter.customerBalance(
                                              TransactionService.getCustomerBalance(
                                                customer.id,
                                              ),
                                            ),
                                            maxLines: 1,
                                            style: TextStyle(
                                              color: colors.primary,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.09),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    status,
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 17,
                                  color: colors.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapTab() {
    const green = Color(0xFF0B5D3B);
    final ink = Theme.of(context).colorScheme.onSurface;
    final customers = routeCustomers;
    final unvisitedCustomers = customers
        .where((c) => !todaysCustomerStatuses.containsKey(c.id))
        .toList();
    final Customer? nextCustomer = unvisitedCustomers.isEmpty
        ? null
        : unvisitedCustomers.first;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => selectedIndex = 0),
                  icon: const Icon(Icons.arrow_back_rounded),
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Text(
                    "Today's Route (Map)",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _loadData,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh route',
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _SalesmanMapPainter()),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SalesmanRoutePainter(
                        stopCount: customers.length,
                      ),
                    ),
                  ),
                ),
                ...List.generate(customers.length.clamp(0, 5).toInt(), (i) {
                  final points = const [
                    Offset(.16, .73),
                    Offset(.31, .54),
                    Offset(.54, .65),
                    Offset(.72, .39),
                    Offset(.49, .20),
                  ];
                  final point = points[i % points.length];
                  final customer = customers[i];
                  final handled = todaysCustomerStatuses.containsKey(
                    customer.id,
                  );
                  return Positioned(
                    left: MediaQuery.of(context).size.width * point.dx - 16,
                    top: (MediaQuery.of(context).size.height - 190) * point.dy,
                    child: GestureDetector(
                      onTap: () => _openCustomer(customer),
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: handled ? const Color(0xFF1985F7) : green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 5,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 14,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(17),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 15,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nextCustomer?.businessName ??
                              (customers.isEmpty
                                  ? 'No route selected'
                                  : 'Route completed'),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          nextCustomer == null
                              ? 'Choose customers for today or review your visits'
                              : 'Next stop · ${nextCustomer.location}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 11),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: nextCustomer == null
                                    ? _chooseTodayRoute
                                    : () => _openCustomer(nextCustomer),
                                icon: const Icon(
                                  Icons.directions_rounded,
                                  size: 16,
                                ),
                                label: const Text(
                                  'Get Directions',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              onPressed: _chooseTodayRoute,
                              icon: const Icon(Icons.tune_rounded),
                              tooltip: 'Edit route',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentsTab() {
    final todayCollection = TransactionService.getCollectedToday();

    final paymentCount = TransactionService.transactions.length;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),

      padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),

      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  Text(
                    'Payments',

                    style: TextStyle(
                      fontSize: 28,

                      fontWeight: FontWeight.w800,

                      letterSpacing: -0.5,
                    ),
                  ),

                  SizedBox(height: 4),

                  Text('All payments received'),
                ],
              ),
            ),

            IconButton.filledTonal(
              tooltip: 'Refresh',

              onPressed: _loadData,

              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),

        const SizedBox(height: 22),

        Row(
          children: [
            Expanded(
              child: _MiniSummaryCard(
                icon: Icons.payments_outlined,

                title: 'Today',

                value: '₹${todayCollection.toStringAsFixed(2)}',
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: _MiniSummaryCard(
                icon: Icons.receipt_long_outlined,

                title: 'Transactions',

                value: paymentCount.toString(),
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),

        Container(
          padding: const EdgeInsets.all(22),

          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),

            borderRadius: BorderRadius.circular(22),

            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),

          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(18),

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,

                  shape: BoxShape.circle,
                ),

                child: Icon(
                  Icons.receipt_long_rounded,

                  size: 38,

                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),

              const SizedBox(height: 18),

              const Text(
                'Payment History',

                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
              ),

              const SizedBox(height: 8),

              Text(
                'View payment amounts, customers, signatures and transaction details.',

                textAlign: TextAlign.center,

                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,

                  height: 1.45,
                ),
              ),

              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,

                child: FilledButton.icon(
                  onPressed: _openPayments,

                  icon: const Icon(Icons.open_in_new_rounded),

                  label: const Text('Open Payment History'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMoreTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),

      children: [
        const Text(
          'More',

          style: TextStyle(
            fontSize: 28,

            fontWeight: FontWeight.w800,

            letterSpacing: -0.5,
          ),
        ),

        const SizedBox(height: 4),

        Text(
          'Account and app settings',

          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: 22),

        Container(
          padding: const EdgeInsets.all(18),

          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),

            borderRadius: BorderRadius.circular(20),
          ),

          child: Row(
            children: [
              _ProfileAvatar(
                initials: _getInitials(widget.userName),

                radius: 28,
              ),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      widget.userName,

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(
                        fontWeight: FontWeight.w800,

                        fontSize: 17,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      'Marketing Executive account',

                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,

            borderRadius: BorderRadius.circular(20),

            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),

          child: Column(
            children: [
              _MoreTile(
                icon: Icons.receipt_long_outlined,
                title: 'Payments received',
                subtitle: 'View payment history and totals',
                onTap: _openPayments,
              ),
              _MoreDivider(),
              _MoreTile(
                icon: Icons.settings_outlined,

                title: 'Settings',

                subtitle: 'Appearance and preferences',

                onTap: _openSettings,
              ),

              _MoreDivider(),

              _MoreTile(
                icon: Icons.refresh_rounded,

                title: 'Refresh Data',

                subtitle: 'Get the latest customers and payments',

                onTap: _loadData,
              ),

              _MoreDivider(),

              _MoreTile(
                icon: Icons.info_outline_rounded,

                title: 'About',

                subtitle: 'Horizon',

                onTap: () {
                  showAboutDialog(
                    context: context,

                    applicationName: 'Horizon',

                    applicationVersion: '1.0.0',

                    applicationIcon: const Icon(
                      Icons.account_balance_wallet_rounded,

                      size: 40,
                    ),

                    children: const [
                      Text(
                        'A business payment and customer ledger application.',
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        Container(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.errorContainer.withValues(alpha: 0.35),

            borderRadius: BorderRadius.circular(20),
          ),

          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,

              vertical: 5,
            ),

            leading: Icon(
              Icons.logout_rounded,

              color: Theme.of(context).colorScheme.error,
            ),

            title: Text(
              'Log out',

              style: TextStyle(
                color: Theme.of(context).colorScheme.error,

                fontWeight: FontWeight.w700,
              ),
            ),

            subtitle: const Text('Sign out of this account'),

            onTap: _logout,
          ),
        ),

        const SizedBox(height: 28),

        Center(
          child: Text(
            'Horizon',

            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,

              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  String _getGreeting() {
    final hour = DateTime.now().toLocal().hour;

    if (hour < 12) {
      return 'Good morning';
    }

    if (hour < 18) {
      return 'Good afternoon';
    }

    return 'Good evening';
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));

    if (parts.isEmpty || parts.first.isEmpty) {
      return 'S';
    }

    if (parts.length == 1) {
      return parts.first[0].toUpperCase();
    }

    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  Future<void> _showTutorialIfNeeded() async {
    if (!await TutorialService.shouldShowOnLogin() || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TutorialScreen(role: 'salesman')),
    );
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();

    _forceLogoutChannel?.unsubscribe();

    searchController.dispose();

    super.dispose();
  }

  int get _phoneNavigationIndex => switch (selectedIndex) {
    0 => 0,
    1 => 1,
    2 => 3,
    _ => 4,
  };

  void _selectPhoneNavigation(int index) {
    if (index == 2) {
      _showPaymentQr();
      return;
    }
    setState(() => selectedIndex = index < 2 ? index : index - 1);
  }

  Widget _navigationRail(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) => setState(() => selectedIndex = index),
      labelType: NavigationRailLabelType.all,
      backgroundColor: colors.surface,
      leading: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 16),
        child: IconButton.filledTonal(
          tooltip: 'Receive payment by QR',
          onPressed: _showPaymentQr,
          icon: const Icon(Icons.qr_code_2_rounded),
        ),
      ),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: Text('Home'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.people_outline_rounded),
          selectedIcon: Icon(Icons.people_rounded),
          label: Text('Customers'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.payments_outlined),
          selectedIcon: Icon(Icons.payments_rounded),
          label: Text('Payments'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('More'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pages = [
      _buildHomeTab(),
      _buildCustomersTab(),
      const SalesmanPaymentsScreen(),
      _buildMoreTab(),
    ];
    final titles = [
      'Horizon',
      "Today's Customers",
      'Payments Received',
      'More',
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= 720;
        final content = Scaffold(
          appBar: AppBar(
            backgroundColor: colors.surface,
            foregroundColor: colors.onSurface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            title: selectedIndex == 0
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          Icons.account_balance_wallet_rounded,
                          color: colors.onPrimary,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 9),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Horizon',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Collection workspace',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  )
                : Text(
                    titles[selectedIndex],
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: isLoading ? null : _loadData,
                icon: const Icon(Icons.refresh_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: isLoading
              ? const Center(child: CircularProgressIndicator())
              : IndexedStack(index: selectedIndex, children: pages),
          bottomNavigationBar: useRail
              ? null
              : Stack(
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.none,
                  children: [
                    NavigationBar(
                      selectedIndex: _phoneNavigationIndex,
                      onDestinationSelected: _selectPhoneNavigation,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home_rounded),
                          label: 'Home',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.people_outline_rounded),
                          selectedIcon: Icon(Icons.people_rounded),
                          label: 'Customers',
                        ),
                        NavigationDestination(
                          icon: SizedBox.shrink(),
                          selectedIcon: SizedBox.shrink(),
                          label: '',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.payments_outlined),
                          selectedIcon: Icon(Icons.payments_rounded),
                          label: 'Payments',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.more_horiz_rounded),
                          selectedIcon: Icon(Icons.more_rounded),
                          label: 'More',
                        ),
                      ],
                    ),
                    Positioned(
                      top: -18,
                      child: FloatingActionButton(
                        heroTag: 'salesman-qr',
                        tooltip: 'Receive payment by QR',
                        onPressed: _showPaymentQr,
                        child: const Icon(Icons.qr_code_2_rounded),
                      ),
                    ),
                  ],
                ),
        );
        if (!useRail) return content;
        return Row(
          children: [
            _navigationRail(context),
            VerticalDivider(width: 1, color: colors.outlineVariant),
            Expanded(child: content),
          ],
        );
      },
    );
  }
}

// ============================================================

class _SalesmanStatusCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final Color background;
  const _SalesmanStatusCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayColor = isDark
        ? Color.lerp(color, Colors.white, 0.32)!
        : color;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        height: 68,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: isDark ? colors.surfaceContainerHigh : background,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 17,
                      height: 1,
                      color: displayColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Icon(icon, color: displayColor, size: 21),
          ],
        ),
      ),
    );
  }
}

class _PaymentQrPainter extends CustomPainter {
  final String data;
  _PaymentQrPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    final qr = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final modules = qr.moduleCount;
    final cell = size.shortestSide / modules;
    final paint = Paint()..color = const Color(0xFF14211A);
    for (var row = 0; row < modules; row++) {
      for (var col = 0; col < modules; col++) {
        if (qr.isDark(row, col)) {
          canvas.drawRect(
            Rect.fromLTWH(col * cell, row * cell, cell + .3, cell + .3),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PaymentQrPainter oldDelegate) =>
      oldDelegate.data != data;
}

class _SalesmanMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFE9F0E8);
    canvas.drawRect(Offset.zero & size, bg);
    final park = Paint()..color = const Color(0xFFD8E9D7);
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .72, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height * .42)
        ..lineTo(size.width * .83, size.height * .35)
        ..close(),
      park,
    );
    final block = Paint()..color = const Color(0xFFF5F2E9);
    for (var i = 0; i < 7; i++) {
      final y = size.height * (i / 7);
      canvas.drawPath(
        Path()
          ..moveTo(0, y + 12)
          ..lineTo(size.width * .42, y - 15)
          ..lineTo(size.width * .57, y + 7)
          ..lineTo(size.width * .2, y + 34)
          ..close(),
        block,
      );
    }
    final minor = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final minorEdge = Paint()
      ..color = const Color(0xFFD9D6CA)
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final paths = <Path>[
      Path()
        ..moveTo(-10, size.height * .17)
        ..lineTo(size.width * .34, size.height * .28)
        ..lineTo(size.width * .52, size.height * .19)
        ..lineTo(size.width + 10, size.height * .31),
      Path()
        ..moveTo(size.width * .04, size.height * .52)
        ..lineTo(size.width * .4, size.height * .42)
        ..lineTo(size.width * .65, size.height * .54)
        ..lineTo(size.width + 10, size.height * .46),
      Path()
        ..moveTo(size.width * .1, size.height * .83)
        ..lineTo(size.width * .4, size.height * .7)
        ..lineTo(size.width * .72, size.height * .78)
        ..lineTo(size.width + 10, size.height * .69),
      Path()
        ..moveTo(size.width * .25, -10)
        ..lineTo(size.width * .43, size.height * .3)
        ..lineTo(size.width * .29, size.height * .57)
        ..lineTo(size.width * .5, size.height + 10),
      Path()
        ..moveTo(size.width * .77, -10)
        ..lineTo(size.width * .62, size.height * .25)
        ..lineTo(size.width * .82, size.height * .53)
        ..lineTo(size.width * .68, size.height + 10),
    ];
    for (final path in paths) {
      canvas.drawPath(path, minorEdge);
      canvas.drawPath(path, minor);
    }
    final route = Paint()
      ..color = const Color(0xFF0B5D3B)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .16, size.height * .76)
        ..lineTo(size.width * .28, size.height * .61)
        ..lineTo(size.width * .43, size.height * .66)
        ..lineTo(size.width * .55, size.height * .49)
        ..lineTo(size.width * .74, size.height * .36)
        ..lineTo(size.width * .53, size.height * .2),
      route,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SalesmanRoutePainter extends CustomPainter {
  final int stopCount;
  const _SalesmanRoutePainter({required this.stopCount});
  @override
  void paint(Canvas canvas, Size size) {
    final current = Paint()
      ..color = const Color(0xFF2587F7)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size.width * .29, size.height * .51), 8, current);
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(Offset(size.width * .29, size.height * .51), 8, white);
  }

  @override
  bool shouldRepaint(covariant _SalesmanRoutePainter oldDelegate) =>
      oldDelegate.stopCount != stopCount;
}

// PROFILE AVATAR

// ============================================================

class _ProfileAvatar extends StatelessWidget {
  final String initials;

  final double radius;

  const _ProfileAvatar({required this.initials, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,

      backgroundColor: Theme.of(context).colorScheme.primaryContainer,

      child: Text(
        initials,

        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,

          fontSize: radius * 0.62,

          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ============================================================

// STAT CARD

// ============================================================

class _StatCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final String value;

  const _StatCard({
    required this.icon,

    required this.title,

    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),

        borderRadius: BorderRadius.circular(18),

        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),

          const SizedBox(height: 14),

          Text(
            value,

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: const TextStyle(
              fontSize: 22,

              fontWeight: FontWeight.w800,

              letterSpacing: -0.4,
            ),
          ),

          const SizedBox(height: 3),

          Text(
            title,

            style: TextStyle(
              fontSize: 12,

              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// MINI SUMMARY CARD

// ============================================================

class _MiniSummaryCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final String value;

  const _MiniSummaryCard({
    required this.icon,

    required this.title,

    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(17),

      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),

        borderRadius: BorderRadius.circular(18),
      ),

      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),

            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,

              borderRadius: BorderRadius.circular(12),
            ),

            child: Icon(
              icon,

              size: 20,

              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),

          const SizedBox(width: 10),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  title,

                  style: TextStyle(
                    fontSize: 12,

                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 3),

                Text(
                  value,

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  style: const TextStyle(
                    fontSize: 17,

                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// QUICK ACTION

// ============================================================

class _QuickAction extends StatelessWidget {
  final IconData icon;

  final String title;

  final String subtitle;

  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,

    required this.title,

    required this.subtitle,

    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,

      borderRadius: BorderRadius.circular(18),

      child: InkWell(
        onTap: onTap,

        borderRadius: BorderRadius.circular(18),

        child: Container(
          padding: const EdgeInsets.all(15),

          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),

            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),

          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,

                  borderRadius: BorderRadius.circular(12),
                ),

                child: Icon(
                  icon,

                  color: Theme.of(context).colorScheme.onPrimaryContainer,

                  size: 21,
                ),
              ),

              const SizedBox(width: 10),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      title,

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(
                        fontWeight: FontWeight.w700,

                        fontSize: 13,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      subtitle,

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: TextStyle(
                        fontSize: 11,

                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================

// CUSTOMER CARD

// ============================================================

class _CustomerCard extends StatelessWidget {
  final Customer customer;

  final double balance;

  final VoidCallback onTap;

  final VoidCallback? onPayment;

  final bool showBalance;

  const _CustomerCard({
    required this.customer,

    required this.balance,

    required this.onTap,

    this.onPayment,

    this.showBalance = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasBalance = balance > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,

        borderRadius: BorderRadius.circular(20),

        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),

      child: InkWell(
        onTap: onTap,

        borderRadius: BorderRadius.circular(20),

        child: Padding(
          padding: const EdgeInsets.all(16),

          child: Row(
            children: [
              Container(
                width: 50,

                height: 50,

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,

                  borderRadius: BorderRadius.circular(15),
                ),

                child: Icon(
                  Icons.storefront_outlined,

                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),

              const SizedBox(width: 13),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      customer.businessName,

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(
                        fontWeight: FontWeight.w800,

                        fontSize: 15,
                      ),
                    ),

                    const SizedBox(height: 5),

                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,

                          size: 14,

                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),

                        const SizedBox(width: 3),

                        Expanded(
                          child: Text(
                            customer.location,

                            maxLines: 1,

                            overflow: TextOverflow.ellipsis,

                            style: TextStyle(
                              fontSize: 12,

                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (showBalance) ...[
                      const SizedBox(height: 8),

                      Row(
                        children: [
                          Text(
                            '₹${balance.toStringAsFixed(2)}',

                            style: TextStyle(
                              fontWeight: FontWeight.w800,

                              fontSize: 14,

                              color: hasBalance
                                  ? Theme.of(context).colorScheme.error
                                  : Colors.green.shade700,
                            ),
                          ),

                          const SizedBox(width: 5),

                          Text(
                            hasBalance ? 'due' : 'paid',

                            style: TextStyle(
                              fontSize: 11,

                              color: hasBalance
                                  ? Theme.of(context).colorScheme.error
                                  : Colors.green.shade700,

                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Column(
                children: [
                  const Icon(Icons.chevron_right_rounded),

                  if (onPayment != null)
                    IconButton(
                      tooltip: 'Receive payment',

                      visualDensity: VisualDensity.compact,

                      onPressed: onPayment,

                      icon: Icon(
                        Icons.payments_outlined,

                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================

// PAYMENT PREVIEW CARD

// ============================================================

class _PaymentPreviewCard extends StatelessWidget {
  final String customerName;

  final double amount;

  final String date;

  final VoidCallback onTap;

  const _PaymentPreviewCard({
    required this.customerName,

    required this.amount,

    required this.date,

    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: ListTile(
          onTap: onTap,

          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 4,
          ),

          leading: Container(
            padding: const EdgeInsets.all(10),

            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,

              borderRadius: BorderRadius.circular(12),
            ),

            child: Icon(
              Icons.payments_outlined,

              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),

          title: Text(
            customerName,

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: const TextStyle(fontWeight: FontWeight.w700),
          ),

          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),

            child: Text(date),
          ),

          trailing: Text(
            '+ ₹${amount.toStringAsFixed(2)}',

            style: TextStyle(
              fontWeight: FontWeight.w800,

              color: Colors.green.shade700,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================

// EMPTY STATE

// ============================================================

class _EmptyState extends StatelessWidget {
  final IconData icon;

  final String title;

  final String subtitle;

  const _EmptyState({
    required this.icon,

    required this.title,

    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),

      padding: const EdgeInsets.all(28),

      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),

        borderRadius: BorderRadius.circular(20),
      ),

      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),

            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,

              shape: BoxShape.circle,
            ),

            child: Icon(
              icon,

              size: 30,

              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),

          const SizedBox(height: 14),

          Text(
            title,

            textAlign: TextAlign.center,

            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),

          const SizedBox(height: 6),

          Text(
            subtitle,

            textAlign: TextAlign.center,

            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,

              height: 1.4,

              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// MORE TILE

// ============================================================

class _MoreTile extends StatelessWidget {
  final IconData icon;

  final String title;

  final String subtitle;

  final VoidCallback onTap;

  const _MoreTile({
    required this.icon,

    required this.title,

    required this.subtitle,

    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),

      leading: Container(
        padding: const EdgeInsets.all(9),

        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,

          borderRadius: BorderRadius.circular(11),
        ),

        child: Icon(
          icon,

          size: 20,

          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),

      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),

      subtitle: Text(subtitle),

      trailing: const Icon(Icons.chevron_right_rounded),

      onTap: onTap,
    );
  }
}

class _MoreDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,

      indent: 18,

      endIndent: 18,

      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
  }
}
