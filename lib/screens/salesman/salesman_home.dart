import 'dart:async';

// Optional legacy dashboard cards remain available for older saved layouts.
// ignore_for_file: unused_element, unused_element_parameter, dead_code, unused_local_variable
import 'package:flutter/material.dart';
import '../../widgets/desktop_workspace.dart';
import '../../services/owner_display_settings.dart';
import '../../services/profile_store.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/root_back_guard.dart';
import '../settings/profile_screen.dart';
import '../../widgets/sydex_ui.dart';
import 'package:flutter/services.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr/qr.dart';

import '../../models/customer.dart';
import '../../models/transaction.dart';

import '../payments/payment_screen.dart';

import 'salesman_customer_screen.dart';

import 'salesman_payments_screen.dart';
import 'salesman_route_map_screen.dart';

import '../../services/customer_service.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';

import '../../services/salesman_visit_service.dart';

import '../settings/settings_screen.dart';

class SalesmanHome extends StatefulWidget {
  final String userName;

  const SalesmanHome({super.key, required this.userName});

  @override
  State<SalesmanHome> createState() => _SalesmanHomeState();
}

class _SalesmanHomeState extends State<SalesmanHome>
    with WidgetsBindingObserver {
  final TextEditingController searchController = TextEditingController();

  final SupabaseClient supabase = Supabase.instance.client;

  int selectedIndex = 0;

  String customerStatusFilter = 'All';

  bool isLoading = true;
  bool _loadRunning = false;
  bool _reloadRequested = false;
  String? _routeLoadError;

  List<String> selectedRouteLocations = <String>[];
  List<String> selectedRouteCustomerIds = <String>[];

  String? selectedRouteName;

  Map<String, String> todaysCustomerStatuses = <String, String>{};

  Timer? _presenceTimer;

  RealtimeChannel? _forceLogoutChannel;

  bool _presenceCheckRunning = false;

  bool _forcedLogoutInProgress = false;

  String get _userName => ProfileStore.name.value ?? widget.userName;

  void _refresh() {
    if (!mounted) return;
    setState(() {
      if (selectedIndex == 3 && !_showMap) selectedIndex = 0;
    });
  }

  bool get _showMap => SalesmanDisplaySettings.show(SalesmanDisplaySettings.map);

  /// Opens the page chosen in My profile, unless already moved elsewhere.
  Future<void> _openStartPage() async {
    await ProfileStore.loadUser();
    final page = ProfileStore.startPage.value;
    if (!mounted || page == 0 || selectedIndex != 0) return;
    if (page == 3 && !_showMap) return;
    setState(() => selectedIndex = page.clamp(0, 3));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ProfileStore.name.addListener(_refresh);
    SalesmanDisplaySettings.values.addListener(_refresh);
    _openStartPage();
    _loadData();

    _startPresenceMonitoring();

    _startForceLogoutListener();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_forcedLogoutInProgress) {
      _loadData();
    }
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
    if (_loadRunning) {
      _reloadRequested = true;
      return;
    }
    _loadRunning = true;
    if (mounted) {
      setState(() {
        isLoading = true;
      });
    }

    SalesmanDisplaySettings.load();
    await CustomerService.loadCustomers();
    await TransactionService.loadTransactions();

    try {
      final locations = await SalesmanVisitService.loadTodayRoute();
      final customerIds =
          await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      selectedRouteLocations = locations;
      selectedRouteCustomerIds = customerIds;
      _routeLoadError = CustomerService.errorMessage == null
          ? null
          : 'Could not refresh customers. Pull down to retry.';
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
      _routeLoadError = 'Could not refresh your route. Pull down to retry.';
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

    _loadRunning = false;
    if (!mounted) return;

    setState(() {
      isLoading = false;
    });
    if (_reloadRequested) {
      _reloadRequested = false;
      unawaited(_loadData());
    }
  }

  List<Customer> get routeCustomers {
    if (selectedRouteCustomerIds.isEmpty) return <Customer>[];

    final customersById = {
      for (final customer in CustomerService.customers) customer.id: customer,
    };
    // Keep assigned customers with an outstanding balance visible. If a
    // customer was settled during today's route, retain them for the rest of
    // the day so the salesman can see the completed visit and receipt.
    return selectedRouteCustomerIds
        .map((id) => customersById[id])
        .whereType<Customer>()
        .where((customer) {
          final status = todaysCustomerStatuses[customer.id];
          return TransactionService.getCustomerBalance(customer.id) > 0 ||
              _isVisitCompleted(status);
        })
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
      final assignedCustomerIds =
          await SalesmanVisitService.loadTodayCustomerIdsInOrder();
      // Customer IDs are the authoritative assignment. Locations are optional
      // display metadata and may be empty for customers without an address.
      if (assigned.isEmpty && assignedCustomerIds.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No route has been assigned for today.'),
          ),
        );
        return;
      }
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
    // The visible list can be empty after every assigned customer is settled,
    // but the saved assignment still needs to be finishable so a queued route
    // can activate.
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
      if (outcome == 'next_route_activated' &&
          selectedRouteCustomerIds.isNotEmpty) {
        // Make the newly activated queued route visible immediately instead of
        // leaving the salesman on the dashboard with the old route context.
        setState(() => selectedIndex = 1);
      }
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
        SnackBar(
          content: Text(
            'Could not finish the route: ${error is PostgrestException ? error.message : error}',
          ),
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
            SettingsScreen(role: 'salesman', userName: _userName),
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
        : 'upi://pay?pa=${Uri.encodeComponent(upi)}&pn=${Uri.encodeComponent('Sydex')}';
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
            'upi://pay?pa=${Uri.encodeComponent(upi)}&pn=${Uri.encodeComponent('Sydex')}';
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
            Text(qrLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
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
              'Confirm the payment before recording it in Sydex.',
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
    final progress = route.isEmpty ? 0.0 : visited / route.length;
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final now = DateTime.now();
    final today = '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
    final heroMuted = Colors.white.withValues(alpha: .62);

    var revealIndex = 0;
    Widget reveal(Widget child) =>
        SydexReveal(index: revealIndex++, child: child);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: SydexPageList(
        maxWidth: 1080,
        children: [
          reveal(
            SydexScreenHeader(
              large: false,
              leading: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ProfileScreen(userName: _userName, role: 'salesman'),
                  ),
                ),
                child: ProfileAvatar(_userName, size: 44),
              ),
              eyebrow: today,
              title: '${_getGreeting()}, $_userName',
              actions: [
                const ThemeToggleButton(),
                SydexIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Refresh data',
                  onPressed: isLoading ? null : _loadData,
                ),
                SydexIconButton(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SydexTwoColumn(
            primary: [
          reveal(
              SydexHeroCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: SydexEyebrow(
                            'Today’s route',
                            color: heroMuted,
                          ),
                        ),
                        if ((selectedRouteName ?? '').isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              selectedRouteName!,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$pending',
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.8,
                            ),
                          ),
                          TextSpan(
                            text: '  customers remaining',
                            style: TextStyle(fontSize: 15, color: heroMuted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: progress),
                        duration: const Duration(milliseconds: 700),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) => LinearProgressIndicator(
                          value: value,
                          minHeight: 4,
                          backgroundColor: Colors.white.withValues(alpha: .18),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _routeLoadError ??
                                (route.isEmpty
                                    ? 'No customers are assigned today.'
                                    : '$visited visited'),
                            style: TextStyle(fontSize: 12, color: heroMuted),
                          ),
                        ),
                        Text(
                          '${route.length} stops',
                          style: TextStyle(fontSize: 12, color: heroMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () => setState(() => selectedIndex = 1),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF141414),
                              minimumSize: const Size(0, 42),
                            ),
                            child: const Text('Open route'),
                          ),
                        ),
                        if (selectedRouteCustomerIds.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _finishRoute,
                              style: OutlinedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: .3),
                                ),
                                minimumSize: const Size(0, 42),
                              ),
                              child: const Text('Finish route'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          reveal(
              SydexAutoGrid(
                minItemWidth: 150,
                itemHeight: 104,
                maxColumns: 4,
                children: [
                  if (SalesmanDisplaySettings.show(SalesmanDisplaySettings.collected))
                    SydexStatTile(
                      label: 'Collected today',
                      value: CurrencyFormatter.rupees(collectedToday),
                    ),
                  SydexStatTile(
                    label: 'Payments received',
                    value: '$paymentCount',
                    footnote: noPayment > 0 ? '$noPayment refused today' : null,
                  ),
                  SydexStatTile(
                    label: 'Visits completed',
                    value: '$visited',
                    footnote: '$paid paid',
                  ),
                  SydexStatTile(
                    label: 'Pending visits',
                    value: '$pending',
                    footnote: SalesmanDisplaySettings.show(SalesmanDisplaySettings.collected)
                        ? 'To collect ${CurrencyFormatter.rupees(pendingCollection)}'
                        : null,
                  ),
                ],
              ),
            ),
            ],
            secondary: [
          if (SalesmanDisplaySettings.show(SalesmanDisplaySettings.qr)) ...[
          reveal(
              SydexCard(
                onTap: _showPaymentQr,
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainer,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        Icons.qr_code_2_rounded,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Receive payment by QR',
                            style: TextStyle(fontWeight: FontWeight.w500),
                          ),
                          Text(
                            'UPI or net banking',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          ],
          if (SalesmanDisplaySettings.show(SalesmanDisplaySettings.recentPayments))
          reveal(
              SydexSection(
                title: 'Recent payments',
                actionLabel: 'See all',
                onAction: _openPayments,
                child: recentPayments.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(
                            'No payments received yet',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < recentPayments.length; i++) ...[
                            if (i > 0)
                              Divider(height: 1, color: colors.outlineVariant),
                            InkWell(
                              onTap: _openPayments,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            recentPayments[i].customerName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          Text(
                                            _formatDate(
                                              recentPayments[i].transactionDate,
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      CurrencyFormatter.rupees(
                                        recentPayments[i].actualAmountReceived,
                                      ),
                                      style: TextStyle(
                                        color: colors.secondary,
                                        fontWeight: FontWeight.w600,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCustomersTab() {
    final colors = Theme.of(context).colorScheme;
    final filters = ['All', 'Pending', 'Visited'];
    final labels = {for (final f in filters) '$f (${_statusCount(f)})': f};
    final selectedLabel = labels.entries
        .firstWhere(
          (entry) => entry.value == customerStatusFilter,
          orElse: () => labels.entries.first,
        )
        .key;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          child: SydexScreenHeader(
            eyebrow: [
              if ((selectedRouteName ?? '').isNotEmpty) selectedRouteName!,
              '${routeCustomers.length} stops',
            ].join(' · '),
            title: 'My route',
            actions: [
              SydexIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Refresh route',
                onPressed: isLoading ? null : _loadData,
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
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: SydexChoiceChips(
            options: labels.keys.toList(),
            selected: selectedLabel,
            onSelected: (label) =>
                setState(() => customerStatusFilter = labels[label] ?? 'All'),
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
                        color: colors.onSurfaceVariant,
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
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
                    children: [
                      SydexCard(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Column(
                          children: [
                            for (
                              var index = 0;
                              index < filteredCustomers.length;
                              index++
                            ) ...[
                              if (index > 0)
                                Divider(
                                  height: 1,
                                  color: colors.outlineVariant,
                                ),
                              _routeRow(filteredCustomers[index]),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
        ),
      ),
    );
  }

  Widget _routeRow(Customer customer) {
    final colors = Theme.of(context).colorScheme;
    final status = _statusLabel(customer);
    final tone = switch (status) {
      'Visited' => SydexTone.positive,
      'Refused today' => SydexTone.negative,
      _ => SydexTone.pending,
    };
    return InkWell(
      onTap: () => _openCustomer(customer),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${selectedRouteCustomerIds.indexOf(customer.id) + 1}.',
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 10),
            SydexAvatar(customer.businessName, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    customer.businessName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    SalesmanDisplaySettings.show(SalesmanDisplaySettings.routeBalances)
                        ? '${customer.location} · ${CurrencyFormatter.customerBalance(TransactionService.getCustomerBalance(customer.id))}'
                        : customer.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  if (status == 'Refused today')
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Already refused today — do not ask again',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.error,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SydexBadge(
              status == 'Refused today' ? 'Refused' : status,
              tone: tone,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapTab() {
    return SalesmanRouteMapScreen(
      onBack: () => setState(() => selectedIndex = 0),
    );
    const green = Color(0xFF141414);
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
                      fontWeight: FontWeight.w600,
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
                        ),
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
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
                            fontWeight: FontWeight.w600,
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

                      fontWeight: FontWeight.w600,

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

                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
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

            fontWeight: FontWeight.w600,

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
                        fontWeight: FontWeight.w600,

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

                subtitle: 'Sydex',

                onTap: () {
                  showAboutDialog(
                    context: context,

                    applicationName: 'Sydex',

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
            'Sydex',

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

  @override
  void dispose() {
    ProfileStore.name.removeListener(_refresh);
    SalesmanDisplaySettings.values.removeListener(_refresh);
    WidgetsBinding.instance.removeObserver(this);
    _presenceTimer?.cancel();

    _forceLogoutChannel?.unsubscribe();

    searchController.dispose();

    super.dispose();
  }

  int get _phoneNavigationIndex => switch (selectedIndex) {
    0 => 0,
    1 => 1,
    2 => 2,
    3 => 3,
    _ => 3,
  };

  void _selectPhoneNavigation(int index) {
    setState(() {
      selectedIndex = switch (index) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        _ => 3,
      };
    });
  }

  Widget _navigationRail(BuildContext context) {
    return DesktopWorkspaceSidebar(
      userName: _userName,
      role: 'Marketing Executive',
      onProfile: _openSettings,
      action: IconButton.filledTonal(
        tooltip: 'Receive payment by QR',
        onPressed: _showPaymentQr,
        icon: const Icon(Icons.qr_code_2_rounded),
      ),
      destinations: [
        for (final item in const <(String, IconData)>[
          ('Overview', Icons.space_dashboard_outlined),
          ('Assigned customers', Icons.people_outline),
          ('Payments', Icons.payments_outlined),
          ('Route map', Icons.map_outlined),
        ].indexed)
          if (item.$1 != 3 || _showMap)
          WorkspaceDestination(
            label: item.$2.$1,
            icon: item.$2.$2,
            selected: selectedIndex == item.$1,
            onTap: () => setState(() => selectedIndex = item.$1),
          ),
        WorkspaceDestination(
          label: 'Settings',
          icon: Icons.settings_outlined,
          onTap: _openSettings,
          secondary: true,
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
      _buildMapTab(),
    ];
    final titles = [
      'Sydex',
      "Today's Customers",
      'Payments Received',
      "Today's Route Map",
    ];

    return RootBackGuard(
      atHome: () => selectedIndex == 0,
      onGoHome: () => setState(() => selectedIndex = 0),
      child: LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= 1000;
        final content = Scaffold(
          body: isLoading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  bottom: false,
                  top: true,
                  child: IndexedStack(
                  index: selectedIndex,
                  children: [
                    for (var i = 0; i < pages.length; i++)
                      TickerMode(
                        enabled: selectedIndex == i,
                        child: WorkspacePageTransition(
                          identity: selectedIndex == i,
                          child: pages[i],
                        ),
                      ),
                  ],
                ),
                ),
          bottomNavigationBar: useRail
              ? null
              : NavigationBar(
                  selectedIndex: _phoneNavigationIndex,
                  onDestinationSelected: _selectPhoneNavigation,
                  destinations: [
                    const NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home_rounded),
                      label: 'Today',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.route_outlined),
                      selectedIcon: Icon(Icons.route_rounded),
                      label: 'Route',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.payments_outlined),
                      selectedIcon: Icon(Icons.payments_rounded),
                      label: 'Payments',
                    ),
                    if (_showMap)
                      const NavigationDestination(
                      icon: Icon(Icons.map_outlined),
                      selectedIcon: Icon(Icons.map_rounded),
                      label: 'Map',
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
      ),
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
                      fontWeight: FontWeight.w600,
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
    final paint = Paint()..color = const Color(0xFF1C1C1C);
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
    final bg = Paint()..color = const Color(0xFFEDECE8);
    canvas.drawRect(Offset.zero & size, bg);
    final park = Paint()..color = const Color(0xFFDEDCD6);
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
      ..color = const Color(0xFF141414)
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

          fontWeight: FontWeight.w600,
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

              fontWeight: FontWeight.w600,

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

                    fontWeight: FontWeight.w600,
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
                        fontWeight: FontWeight.w600,

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
                              fontWeight: FontWeight.w600,

                              fontSize: 14,

                              color: hasBalance
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),

                          const SizedBox(width: 5),

                          Text(
                            hasBalance ? 'due' : 'paid',

                            style: TextStyle(
                              fontSize: 11,

                              color: hasBalance
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.onSurfaceVariant,

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
              fontWeight: FontWeight.w600,

              color: Theme.of(context).colorScheme.onSurfaceVariant,
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

            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
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
      ),
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
