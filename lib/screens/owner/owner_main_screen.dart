import 'package:flutter/material.dart';
import '../../widgets/desktop_workspace.dart';
import 'old_card_import_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Optional owner helpers remain available for compatibility with older layouts.
// ignore_for_file: unused_field, unused_element, unused_element_parameter
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import '../purchases/add_purchase_screen.dart';

import '../payments/payment_screen.dart';

import '../customers/customers_screen.dart';
import '../customers/add_customer_screen.dart';

import '../../models/customer.dart';

import '../../models/transaction.dart';

import '../../services/customer_service.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/payment_method_breakdown.dart';

import '../settings/settings_screen.dart';
import '../settings/profile_screen.dart';

import 'owner_reports_screen.dart';
import 'owner_dashboard.dart';

import 'salesman_visit_audit_screen.dart';
import 'owner_route_management_screen.dart';
import 'owner_notifications_screen.dart';
import 'owner_ai_assistant_screen.dart';
import '../../widgets/edit_payment_dialog.dart';

class OwnerMainScreen extends StatefulWidget {
  final String userName;

  const OwnerMainScreen({super.key, this.userName = 'Owner'});

  @override
  State<OwnerMainScreen> createState() => _OwnerMainScreenState();
}

class _OwnerMainScreenState extends State<OwnerMainScreen> {
  int _selectedIndex = 0;
  bool _showMobileRoutes = false;
  final Set<int> _visitedDesktopPages = {0};

  bool _isInitialLoading = true;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadData();
      }
    });
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _isInitialLoading = true;
      });
    }

    try {
      await CustomerService.loadCustomers();
      // Balances and transactions are independent once customers are loaded.
      // Fetch them together to reduce dashboard startup latency.
      await Future.wait([
        TransactionService.loadCustomerBalances(),
        TransactionService.loadTransactions(),
      ]);
    } finally {
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
        });
      }
    }
  }

  Future<void> _openAddPurchase() async {
    final result = await Navigator.push<bool>(
      context,

      MaterialPageRoute(builder: (_) => const AddPurchaseScreen()),
    );

    if (result == true && mounted) {
      await _loadData();
    }
  }

  void _openCustomers() {
    setState(() {
      _selectedIndex = 1;
    });
  }

  void _openAddCustomer() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddCustomerScreen()),
    );
  }

  void _openPayments() {
    setState(() {
      _selectedIndex = 2;
    });
  }

  void _openNotifications() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OwnerNotificationsScreen()),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openReports() {
    setState(() {
      _selectedIndex = 3;
    });
  }

  Future<void> _openVisitAudit() async {
    await Navigator.push(
      context,

      MaterialPageRoute(builder: (_) => const SalesmanVisitAuditScreen()),
    );
  }

  void _openPlaces() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const OwnerRouteManagementScreen(page: OwnerRoutePage.places),
      ),
    );
  }

  void _openSalesmen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const OwnerRouteManagementScreen(page: OwnerRoutePage.salesmen),
      ),
    );
  }

  void _openRouteMap() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const OwnerRouteManagementScreen(page: OwnerRoutePage.map),
      ),
    );
  }

  Future<void> _openReceivePayment() async {
    final customer = await showModalBottomSheet<Customer>(
      context: context,

      isScrollControlled: true,

      backgroundColor: Colors.transparent,

      builder: (_) => const _PaymentCustomerPicker(),
    );

    if (customer == null || !mounted) return;

    final saved = await Navigator.push<bool>(
      context,

      MaterialPageRoute(builder: (_) => PaymentScreen(customer: customer)),
    );

    if (saved == true && mounted) {
      await _loadData();
    }
  }

  void _openSettings() {
    Navigator.push(
      context,

      MaterialPageRoute(
        builder: (_) =>
            SettingsScreen(role: 'owner', userName: widget.userName),
      ),
    );
  }

  void _openAIAssistant() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OwnerAIAssistantScreen()),
    );
  }

  Widget _desktopToolbar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(Icons.workspaces_outline, color: colors.primary, size: 18),
          const SizedBox(width: 10),
          const Text(
            'Owner workspace',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _openAddCustomer,
            icon: const Icon(Icons.person_add_alt_1, size: 17),
            label: const Text('Add customer'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _openAddPurchase,
            icon: const Icon(Icons.add, size: 17),
            label: const Text('Add sale'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _openReceivePayment,
            icon: const Icon(Icons.south_west, size: 17),
            label: const Text('Receive payment'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);

    // The MaterialApp owns the active brand accent. Reusing it here keeps
    // every owner page in sync with the saved business appearance.
    final colors = baseTheme.colorScheme;

    final polishedTheme = baseTheme.copyWith(
      colorScheme: colors,

      scaffoldBackgroundColor: colors.surfaceContainerLowest,

      appBarTheme: baseTheme.appBarTheme.copyWith(
        backgroundColor: colors.surfaceContainerLowest,

        surfaceTintColor: Colors.transparent,

        elevation: 0,

        scrolledUnderElevation: 0,

        titleTextStyle: TextStyle(
          color: colors.onSurface,

          fontSize: 20,

          fontWeight: FontWeight.w800,
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        height: 64,

        backgroundColor: colors.surface,

        indicatorColor: Colors.transparent,

        elevation: 8,

        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 10,

            fontWeight: FontWeight.w700,

            color: colors.onSurface,
          ),
        ),
      ),

      cardTheme: baseTheme.cardTheme.copyWith(
        elevation: 0,

        margin: EdgeInsets.zero,

        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
    );

    final pages = [
      OwnerDashboard(
        userName: widget.userName,
        onRecordPurchase: _openAddPurchase,
        onAddCustomer: _openAddCustomer,
        onOpenCustomers: _openCustomers,
        onOpenPayments: _openPayments,
        onOpenNotifications: _openNotifications,
        onOpenVisitAudit: _openVisitAudit,
        onOpenRoute: _openPlaces,
      ),

      const CustomersScreen(),

      const PaymentsScreen(),

      const OwnerReportsScreen(),
    ];

    _visitedDesktopPages.add(_selectedIndex);
    final desktopPages = <Widget>[
      OwnerDashboard(
        userName: widget.userName,
        onOpenPayments: _openPayments,
        onOpenNotifications: _openNotifications,
        onOpenCustomers: _openCustomers,
        onOpenVisitAudit: _openVisitAudit,
        onOpenRoute: _openPlaces,
        onAddCustomer: _openAddCustomer,
        onRecordPurchase: _openAddPurchase,
      ),
      const CustomersScreen(),
      const PaymentsScreen(),
      const OwnerReportsScreen(),
      const OwnerRouteManagementScreen(page: OwnerRoutePage.places),
      const OwnerRouteManagementScreen(page: OwnerRoutePage.salesmen),
      const OwnerRouteManagementScreen(page: OwnerRoutePage.map),
      const SalesmanVisitAuditScreen(),
      const OldCardImportScreen(),
      const OwnerAIAssistantScreen(),
      const OwnerNotificationsScreen(),
      SettingsScreen(role: 'owner', userName: widget.userName),
    ];

    return Theme(
      data: polishedTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Desktop builds should use the desktop navigation even when Windows
          // display scaling makes the logical window width fall below 1100 px.
          final isNativeDesktop = switch (defaultTargetPlatform) {
            TargetPlatform.windows ||
            TargetPlatform.macOS ||
            TargetPlatform.linux => true,
            _ => false,
          };
          // Use the same width breakpoints on desktop and mobile so a narrow
          // desktop window does not force the wide sidebar layout.
          final isDesktop =
              constraints.maxWidth >= (isNativeDesktop ? 900 : 1100);
          if (isDesktop) {
            return Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              body: Row(
                children: [
                  DesktopWorkspaceSidebar(
                    userName: widget.userName,
                    role: 'Owner',
                    onProfile: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(
                          userName: widget.userName,
                          role: 'owner',
                        ),
                      ),
                    ),
                    destinations: [
                      for (final item in const <(String, IconData)>[
                        ('Overview', Icons.space_dashboard_outlined),
                        ('Customers', Icons.people_outline_rounded),
                        (
                          'Payments & ledger',
                          Icons.account_balance_wallet_outlined,
                        ),
                        ('Reports', Icons.bar_chart_rounded),
                        ('Routes & areas', Icons.route_outlined),
                        ('Team assignments', Icons.badge_outlined),
                        ('Route map', Icons.map_outlined),
                        ('Visit audit', Icons.fact_check_outlined),
                        ('Import old cards', Icons.document_scanner_outlined),
                        ('Sydie assistant', Icons.auto_awesome_outlined),
                        ('Notifications', Icons.notifications_none_rounded),
                        ('Settings', Icons.settings_outlined),
                      ].indexed)
                        WorkspaceDestination(
                          label: item.$2.$1,
                          icon: item.$2.$2,
                          selected: _selectedIndex == item.$1,
                          secondary: item.$1 == 7 || item.$1 == 11,
                          onTap: () => setState(() => _selectedIndex = item.$1),
                        ),
                    ],
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _desktopToolbar(context),
                        Expanded(
                          child: IndexedStack(
                            index: _selectedIndex.clamp(
                              0,
                              desktopPages.length - 1,
                            ),
                            children: [
                              for (var i = 0; i < desktopPages.length; i++)
                                _visitedDesktopPages.contains(i)
                                    ? TickerMode(
                                        enabled: _selectedIndex == i,
                                        child: WorkspacePageTransition(
                                          identity: _selectedIndex == i,
                                          child: desktopPages[i],
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          return Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: const Text(
                'Sydex',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              actions: [
                IconButton(
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: _showMobileRoutes
                ? const OwnerRouteManagementScreen(page: OwnerRoutePage.places)
                : IndexedStack(
                    index: _selectedIndex.clamp(0, 3),
                    children: pages,
                  ),
            floatingActionButton: FloatingActionButton.small(
              heroTag: 'sydie-mobile-fab',
              tooltip: 'Open Sydie assistant',
              onPressed: _openAIAssistant,
              child: const Icon(Icons.auto_awesome_rounded, size: 19),
            ),
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _showMobileRoutes ? 4 : _selectedIndex.clamp(0, 3),
              onDestinationSelected: (index) {
                setState(() {
                  _showMobileRoutes = index == 4;
                  if (index < 4) _selectedIndex = index;
                });
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.people_outline_rounded),
                  selectedIcon: Icon(Icons.people_rounded),
                  label: 'Customers',
                ),
                NavigationDestination(
                  icon: Icon(Icons.payments_outlined),
                  selectedIcon: Icon(Icons.payments_rounded),
                  label: 'Payments',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bar_chart_outlined),
                  selectedIcon: Icon(Icons.bar_chart_rounded),
                  label: 'Reports',
                ),
                NavigationDestination(
                  icon: Icon(Icons.route_outlined),
                  selectedIcon: Icon(Icons.route_rounded),
                  label: 'Routes',
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OwnerHomeContent extends StatelessWidget {
  final String userName;

  final VoidCallback onAddPurchase;

  final VoidCallback onOpenCustomers;

  final VoidCallback onOpenPayments;

  final VoidCallback onOpenNotifications;

  final VoidCallback onOpenReports;

  final VoidCallback onOpenVisitAudit;

  final VoidCallback onReceivePayment;

  final VoidCallback onOpenSettings;

  final bool isInitialLoading;

  const _OwnerHomeContent({
    required this.userName,

    required this.onAddPurchase,

    required this.onOpenCustomers,

    required this.onOpenPayments,
    required this.onOpenNotifications,

    required this.onOpenReports,

    required this.onOpenVisitAudit,

    required this.onReceivePayment,

    required this.onOpenSettings,

    required this.isInitialLoading,
  });

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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surfaceContainerLowest,

      appBar: AppBar(
        backgroundColor: colors.surfaceContainerLowest,

        elevation: 0,

        titleSpacing: 20,

        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            Text(
              _getGreeting(),

              style: TextStyle(
                fontSize: 11,

                fontWeight: FontWeight.w600,

                color: colors.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 2),

            const Text(
              'Business Overview',

              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ],
        ),

        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: onOpenNotifications,
            icon: const Icon(Icons.notifications_none_rounded),
          ),
          IconButton(
            tooltip: 'Settings',

            onPressed: onOpenSettings,

            icon: const Icon(Icons.settings_outlined),
          ),

          const SizedBox(width: 8),
        ],
      ),

      body: isInitialLoading
          ? Center(child: CircularProgressIndicator(color: colors.primary))
          : ValueListenableBuilder<int>(
              valueListenable: CustomerService.dataVersion,

              builder: (context, customerVersion, child) {
                return ValueListenableBuilder<int>(
                  valueListenable: TransactionService.dataVersion,

                  builder: (context, transactionVersion, child) {
                    return RefreshIndicator(
                      color: colors.primary,

                      backgroundColor: colors.surface,

                      onRefresh: () async {
                        await CustomerService.loadCustomers();

                        await TransactionService.loadCustomerBalances();

                        await TransactionService.loadTransactions();
                      },

                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),

                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),

                        children: [
                          const _DashboardSummary(),

                          const SizedBox(height: 18),

                          Text(
                            'Quick Actions',

                            style: TextStyle(
                              color: colors.onSurface,

                              fontSize: 16,

                              fontWeight: FontWeight.w800,
                            ),
                          ),

                          const SizedBox(height: 8),

                          Row(
                            children: [
                              Expanded(
                                child: _QuickAction(
                                  icon: Icons.people_alt_outlined,

                                  title: 'Customers',

                                  subtitle: 'Manage customers',

                                  onTap: onOpenCustomers,

                                  colors: colors,
                                ),
                              ),

                              const SizedBox(width: 12),

                              Expanded(
                                child: _QuickAction(
                                  icon: Icons.payments_outlined,

                                  title: 'Payments',

                                  subtitle: 'View collections',

                                  onTap: onOpenPayments,

                                  colors: colors,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          Row(
                            children: [
                              Expanded(
                                child: _QuickAction(
                                  icon: Icons.account_balance_wallet_outlined,

                                  title: 'Receive Payment',

                                  subtitle: 'Collect from a customer',

                                  onTap: onReceivePayment,

                                  colors: colors,
                                ),
                              ),

                              const SizedBox(width: 12),

                              Expanded(
                                child: _QuickAction(
                                  icon: Icons.bar_chart_rounded,

                                  title: 'Reports',

                                  subtitle: 'View business reports',

                                  onTap: onOpenReports,

                                  colors: colors,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          Row(
                            children: [
                              Expanded(
                                child: _QuickAction(
                                  icon: Icons.location_searching_rounded,

                                  title: 'Visit audit',

                                  subtitle: 'Verify salesman locations',

                                  onTap: onOpenVisitAudit,

                                  colors: colors,
                                ),
                              ),

                              const SizedBox(width: 12),

                              const Expanded(child: SizedBox.shrink()),
                            ],
                          ),

                          const SizedBox(height: 26),

                          Text(
                            'Today',

                            style: TextStyle(
                              color: colors.onSurface,

                              fontSize: 18,

                              fontWeight: FontWeight.w800,
                            ),
                          ),

                          const SizedBox(height: 12),

                          const _TodayCard(),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

// ============================================================

// PAYMENT CUSTOMER PICKER

// ============================================================

class _PaymentCustomerPicker extends StatefulWidget {
  const _PaymentCustomerPicker();

  @override
  State<_PaymentCustomerPicker> createState() => _PaymentCustomerPickerState();
}

class _PaymentCustomerPickerState extends State<_PaymentCustomerPicker> {
  final TextEditingController _searchController = TextEditingController();

  String _query = '';

  @override
  void initState() {
    super.initState();

    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();

    super.dispose();
  }

  void _onSearchChanged() {
    if (!mounted) return;

    setState(() {
      _query = _searchController.text.trim().toLowerCase();
    });
  }

  List<Customer> _filteredCustomers() {
    final customers = CustomerService.customers;

    if (_query.isEmpty) return customers;

    return customers.where((customer) {
      return customer.businessName.toLowerCase().contains(_query) ||
          customer.location.toLowerCase().contains(_query) ||
          customer.phone.toLowerCase().contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final customers = _filteredCustomers();

    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.82,

        decoration: BoxDecoration(
          color: colors.surface,

          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),

        child: Column(
          children: [
            const SizedBox(height: 10),

            Container(
              width: 42,

              height: 4,

              decoration: BoxDecoration(
                color: colors.outlineVariant,

                borderRadius: BorderRadius.circular(10),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),

              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Select Customer',

                      style: TextStyle(
                        fontSize: 20,

                        fontWeight: FontWeight.w800,

                        color: colors.onSurface,
                      ),
                    ),
                  ),

                  IconButton(
                    onPressed: () => Navigator.pop(context),

                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),

              child: TextField(
                controller: _searchController,

                textInputAction: TextInputAction.search,

                decoration: InputDecoration(
                  hintText: 'Search customer, location or phone',

                  prefixIcon: const Icon(Icons.search_rounded),

                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _searchController.clear,

                          icon: const Icon(Icons.clear_rounded),
                        ),

                  filled: true,

                  fillColor: colors.surfaceContainerHighest,

                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),

                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            Expanded(
              child: customers.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'No customers available.'
                            : 'No matching customers.',

                        style: TextStyle(
                          color: colors.onSurfaceVariant,

                          fontSize: 14,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),

                      itemCount: customers.length,

                      separatorBuilder: (_, _) => const SizedBox(height: 8),

                      itemBuilder: (context, index) {
                        final customer = customers[index];

                        final balance = TransactionService.getCustomerBalance(
                          customer.id,
                        );

                        return Material(
                          color: colors.surfaceContainerLowest,

                          borderRadius: BorderRadius.circular(16),

                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),

                            onTap: () => Navigator.pop(context, customer),

                            child: Padding(
                              padding: const EdgeInsets.all(15),

                              child: Row(
                                children: [
                                  Container(
                                    width: 44,

                                    height: 44,

                                    decoration: BoxDecoration(
                                      color: colors.primaryContainer,

                                      borderRadius: BorderRadius.circular(13),
                                    ),

                                    child: Icon(
                                      Icons.storefront_outlined,

                                      color: Colors.white,
                                    ),
                                  ),

                                  const SizedBox(width: 12),

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
                                            color: colors.onSurface,

                                            fontSize: 14,

                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),

                                        const SizedBox(height: 4),

                                        Text(
                                          customer.location,

                                          maxLines: 1,

                                          overflow: TextOverflow.ellipsis,

                                          style: TextStyle(
                                            color: colors.onSurfaceVariant,

                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(width: 10),

                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,

                                    children: [
                                      Text(
                                        '₹${balance.toStringAsFixed(2)}',

                                        style: TextStyle(
                                          color: colors.primary,

                                          fontSize: 13,

                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),

                                      const SizedBox(height: 3),

                                      Text(
                                        'Due',

                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,

                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================

// DASHBOARD SUMMARY

// ============================================================

class _DashboardSummary extends StatelessWidget {
  const _DashboardSummary();

  String _formatCurrency(double amount) {
    return '₹${amount.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final customers = CustomerService.customers;

    final outstanding = TransactionService.customerBalances.values.fold<double>(
      0.0,

      (total, balance) => total + (balance > 0 ? balance : 0),
    );

    final collected = TransactionService.getCollectedToday();

    return Column(
      children: [
        Container(
          width: double.infinity,

          padding: const EdgeInsets.all(22),

          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,

              end: Alignment.bottomRight,

              colors: [
                colors.primary,

                Color.lerp(colors.primary, Colors.black, 0.38)!,
              ],
            ),

            borderRadius: BorderRadius.circular(22),

            boxShadow: [
              BoxShadow(
                color: colors.primary.withValues(alpha: 0.18),

                blurRadius: 22,

                offset: const Offset(0, 10),
              ),
            ],
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Row(
                children: [
                  Container(
                    width: 42,

                    height: 42,

                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),

                      borderRadius: BorderRadius.circular(12),
                    ),

                    child: const Icon(
                      Icons.account_balance_wallet_outlined,

                      color: Colors.white,

                      size: 21,
                    ),
                  ),

                  const SizedBox(width: 12),

                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [
                        Text(
                          'Money to Receive',

                          style: TextStyle(
                            color: Colors.white,

                            fontSize: 14,

                            fontWeight: FontWeight.w700,
                          ),
                        ),

                        SizedBox(height: 3),

                        Text(
                          'Current outstanding balance',

                          style: TextStyle(
                            color: Color(0xBFFFFFFF),

                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 22),

              Text(
                _formatCurrency(outstanding),

                style: const TextStyle(
                  color: Colors.white,

                  fontSize: 33,

                  fontWeight: FontWeight.w800,

                  letterSpacing: -1,
                ),
              ),

              const SizedBox(height: 16),

              Row(
                children: [
                  _SmallWhiteStat(
                    icon: Icons.people_outline_rounded,

                    text: '${customers.length} customers',
                  ),

                  const SizedBox(width: 18),

                  _SmallWhiteStat(
                    icon: Icons.payments_outlined,

                    text: '${_formatCurrency(collected)} collected today',
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: _SmallStatCard(
                icon: Icons.people_outline_rounded,

                title: 'Customers',

                value: '${customers.length}',

                colors: colors,
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: _SmallStatCard(
                icon: Icons.payments_outlined,

                title: 'Collected Today',

                value: _formatCurrency(collected),

                colors: colors,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================

// PRIMARY ACTION

// ============================================================

class _PrimaryActionCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final String subtitle;

  final VoidCallback onTap;

  final ColorScheme colors;

  const _PrimaryActionCard({
    required this.icon,

    required this.title,

    required this.subtitle,

    required this.onTap,

    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,

      borderRadius: BorderRadius.circular(18),

      child: InkWell(
        onTap: onTap,

        borderRadius: BorderRadius.circular(18),

        child: Container(
          padding: const EdgeInsets.all(17),

          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),

            border: Border.all(color: colors.outlineVariant),
          ),

          child: Row(
            children: [
              Container(
                width: 50,

                height: 50,

                decoration: BoxDecoration(
                  color: colors.primary,

                  borderRadius: BorderRadius.circular(15),
                ),

                child: Icon(icon, color: colors.onPrimary, size: 23),
              ),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      title,

                      style: TextStyle(
                        color: colors.onSurface,

                        fontSize: 14,

                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const SizedBox(height: 4),

                    Text(
                      subtitle,

                      style: TextStyle(
                        color: colors.onSurfaceVariant,

                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              Icon(
                Icons.arrow_forward_ios_rounded,

                size: 15,

                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
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

  final ColorScheme colors;

  const _QuickAction({
    required this.icon,

    required this.title,

    required this.subtitle,

    required this.onTap,

    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surface,

      borderRadius: BorderRadius.circular(17),

      child: InkWell(
        onTap: onTap,

        borderRadius: BorderRadius.circular(17),

        child: Container(
          padding: const EdgeInsets.all(15),

          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),

            border: Border.all(color: colors.outlineVariant),
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Container(
                width: 40,

                height: 40,

                decoration: BoxDecoration(
                  color: colors.primaryContainer,

                  borderRadius: BorderRadius.circular(12),
                ),

                child: Icon(icon, color: colors.onPrimaryContainer, size: 20),
              ),

              const SizedBox(height: 12),

              Text(
                title,

                style: TextStyle(
                  color: colors.onSurface,

                  fontSize: 13,

                  fontWeight: FontWeight.w700,
                ),
              ),

              const SizedBox(height: 3),

              Text(
                subtitle,

                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================

// TODAY CARD

// ============================================================

class _TodayCard extends StatelessWidget {
  const _TodayCard();

  String _formatCurrency(double amount) {
    return '₹${amount.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final collected = TransactionService.getCollectedToday();

    final payments = TransactionService.getPaymentsToday();

    return Container(
      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: colors.surface,

        borderRadius: BorderRadius.circular(18),

        border: Border.all(color: colors.outlineVariant),
      ),

      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,

                height: 42,

                decoration: BoxDecoration(
                  color: colors.primaryContainer,

                  borderRadius: BorderRadius.circular(12),
                ),

                child: Icon(
                  Icons.trending_up_rounded,

                  color: colors.onPrimaryContainer,

                  size: 21,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      "Today's Collection",

                      style: TextStyle(
                        color: colors.onSurface,

                        fontSize: 14,

                        fontWeight: FontWeight.w700,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      'Payments received today',

                      style: TextStyle(
                        color: colors.onSurfaceVariant,

                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              Text(
                _formatCurrency(collected),

                style: TextStyle(
                  color: colors.primary,

                  fontSize: 16,

                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),

          const SizedBox(height: 17),

          Divider(height: 1, color: colors.outlineVariant),

          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: _TodayStat(
                  icon: Icons.receipt_long_outlined,

                  label: 'Payments',

                  value: '$payments',

                  colors: colors,
                ),
              ),

              Container(width: 1, height: 30, color: colors.outlineVariant),

              Expanded(
                child: _TodayStat(
                  icon: Icons.account_balance_wallet_outlined,

                  label: 'Collected',

                  value: _formatCurrency(collected),

                  colors: colors,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================

// SMALL STAT CARD

// ============================================================

class _SmallStatCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final String value;

  final ColorScheme colors;

  const _SmallStatCard({
    required this.icon,

    required this.title,

    required this.value,

    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),

      decoration: BoxDecoration(
        color: colors.surface,

        borderRadius: BorderRadius.circular(17),

        border: Border.all(color: colors.outlineVariant),
      ),

      child: Row(
        children: [
          Container(
            width: 36,

            height: 36,

            decoration: BoxDecoration(
              color: colors.primaryContainer,

              borderRadius: BorderRadius.circular(10),
            ),

            child: Icon(icon, size: 18, color: colors.onPrimaryContainer),
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

                  style: TextStyle(
                    color: colors.onSurfaceVariant,

                    fontSize: 10,
                  ),
                ),

                const SizedBox(height: 3),

                Text(
                  value,

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(
                    color: colors.onSurface,

                    fontSize: 14,

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

// SMALL WHITE STAT

// ============================================================

class _SmallWhiteStat extends StatelessWidget {
  final IconData icon;

  final String text;

  const _SmallWhiteStat({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,

        children: [
          Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.82)),

          const SizedBox(width: 5),

          Flexible(
            child: Text(
              text,

              maxLines: 1,

              overflow: TextOverflow.ellipsis,

              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),

                fontSize: 10,

                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// TODAY STAT

// ============================================================

class _TodayStat extends StatelessWidget {
  final IconData icon;

  final String label;

  final String value;

  final ColorScheme colors;

  const _TodayStat({
    required this.icon,

    required this.label,

    required this.value,

    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,

      children: [
        Icon(icon, size: 17, color: colors.primary),

        const SizedBox(width: 7),

        Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            Text(
              label,

              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10),
            ),

            const SizedBox(height: 2),

            Text(
              value,

              style: TextStyle(
                color: colors.onSurface,

                fontSize: 13,

                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================

// PAYMENTS SCREEN

// ============================================================

class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _ledgerHorizontalController = ScrollController();
  String _searchQuery = '';
  String _dateFilter = 'all';
  String _methodFilter = 'all';
  DateTime? _selectedDate;
  DateTimeRange? _selectedDateRange;
  List<Map<String, dynamic>> _refusedPayments = const [];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    CustomerService.dataVersion.addListener(_onCustomersChanged);
    _loadRefusedPayments();
  }

  Future<void> _loadRefusedPayments() async {
    try {
      final rows = await Supabase.instance.client
          .from('salesman_customer_daily_status')
          .select(
            'id, customer_id, status_date, created_at, note, entered_by, customers(business_name, location)',
          )
          .eq('status', 'rejected')
          .order('status_date', ascending: false);
      if (mounted) {
        setState(
          () => _refusedPayments = List<Map<String, dynamic>>.from(rows),
        );
      }
    } catch (error) {
      debugPrint('Could not load refused payment history: $error');
    }
  }

  List<Map<String, dynamic>> _filteredRefusedPayments() {
    if (_methodFilter != 'all' && _methodFilter != 'refused') return const [];
    final query = _searchQuery;
    return _refusedPayments.where((row) {
      final date = DateTime.tryParse(
        row['created_at']?.toString() ?? '${row['status_date']}T00:00:00',
      );
      if (date == null) return false;
      final day = DateTime(date.year, date.month, date.day);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      switch (_dateFilter) {
        case 'today':
          if (day != today) return false;
        case 'week':
          final start = today.subtract(Duration(days: today.weekday - 1));
          if (day.isBefore(start) || day.isAfter(today)) return false;
        case 'month':
          if (day.year != today.year || day.month != today.month) return false;
        case 'date':
          final range = _selectedDateRange;
          if (range != null) {
            final start = DateTime(
              range.start.year,
              range.start.month,
              range.start.day,
            );
            final end = DateTime(
              range.end.year,
              range.end.month,
              range.end.day,
            );
            if (day.isBefore(start) || day.isAfter(end)) return false;
          } else if (_selectedDate != null &&
              day !=
                  DateTime(
                    _selectedDate!.year,
                    _selectedDate!.month,
                    _selectedDate!.day,
                  )) {
            return false;
          }
      }
      final customer = row['customers'];
      final name = customer is Map
          ? customer['business_name']?.toString() ?? ''
          : '';
      final note = row['note']?.toString() ?? '';
      return query.isEmpty ||
          name.toLowerCase().contains(query) ||
          note.toLowerCase().contains(query);
    }).toList();
  }

  Widget _buildRefusedPaymentCard(
    Map<String, dynamic> row,
    ColorScheme colors,
  ) {
    final customer = row['customers'];
    final name = customer is Map
        ? customer['business_name']?.toString() ?? 'Customer'
        : 'Customer';
    final date = row['status_date']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 1),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        border: Border(bottom: BorderSide(color: colors.surface)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.block_outlined, color: colors.error, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Refused • $date • ${row['note'] ?? 'Customer refused payment'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
                Text(
                  CurrencyFormatter.currentAmountDue(
                    TransactionService.getCustomerBalance(
                      row['customer_id']?.toString() ?? '',
                    ),
                  ),
                  style: TextStyle(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Refused',
            style: TextStyle(color: colors.error, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  Future<void> _hidePayment(PaymentTransaction payment) async {
    try {
      await Supabase.instance.client.rpc(
        'set_payment_hidden_from_ledger',
        params: {'p_payment_id': payment.id, 'p_hidden': true},
      );
    } catch (error) {
      debugPrint('Could not sync hidden payment visibility: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not hide payment: $error')),
        );
      }
      return;
    }
    await TransactionService.loadTransactions();
  }

  @override
  void dispose() {
    CustomerService.dataVersion.removeListener(_onCustomersChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _ledgerHorizontalController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
  }

  void _onCustomersChanged() {
    if (!mounted) return;
    // CustomerService can notify while a ValueListenableBuilder is painting.
    // Defer the rebuild to the next frame to avoid setState-during-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  String _money(double value) => '₹${value.abs().toStringAsFixed(2)}';

  double _amountForCurrentMethod(PaymentTransaction payment) {
    if (payment.isBounced) return 0;
    if (_methodFilter == 'all') return payment.actualAmountReceived;
    final hasSplit = PaymentMethodBreakdown.parse(
      payment.paymentMethodNote,
    ).isNotEmpty;
    return PaymentMethodBreakdown.amountFor(
      note: payment.paymentMethodNote,
      method: _methodFilter,
      fallbackAmount: hasSplit ? 0 : payment.actualAmountReceived,
    );
  }

  bool _matchesDate(PaymentTransaction payment) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = payment.transactionDate.toLocal();
    final day = DateTime(date.year, date.month, date.day);
    switch (_dateFilter) {
      case 'today':
        return day == today;
      case 'week':
        final start = today.subtract(Duration(days: today.weekday - 1));
        return !day.isBefore(start) && !day.isAfter(today);
      case 'month':
        return day.year == today.year && day.month == today.month;
      case 'date':
        final range = _selectedDateRange;
        if (range != null) {
          final start = DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          );
          final end = DateTime(range.end.year, range.end.month, range.end.day);
          return !day.isBefore(start) && !day.isAfter(end);
        }
        if (_selectedDate == null) return true;
        return day ==
            DateTime(
              _selectedDate!.year,
              _selectedDate!.month,
              _selectedDate!.day,
            );
      default:
        return true;
    }
  }

  List<PaymentTransaction> _filteredPayments() {
    final payments = TransactionService.transactions.where((payment) {
      if (payment.isHiddenFromLedger) return false;
      if (!_matchesDate(payment)) return false;
      if (_methodFilter != 'all') {
        final method = payment.paymentMethod.trim().toLowerCase().replaceAll(
          ' ',
          '_',
        );
        if (method != _methodFilter &&
            !PaymentMethodBreakdown.includes(
              payment.paymentMethodNote,
              _methodFilter,
            )) {
          return false;
        }
      }
      if (_searchQuery.isEmpty) return true;
      return payment.customerName.toLowerCase().contains(_searchQuery) ||
          payment.paymentMethod.toLowerCase().contains(_searchQuery) ||
          payment.notes.toLowerCase().contains(_searchQuery);
    }).toList();
    payments.sort((a, b) {
      final dateOrder = b.transactionDate.compareTo(a.transactionDate);
      if (dateOrder != 0) return dateOrder;
      return (b.createdAt ?? b.transactionDate).compareTo(
        a.createdAt ?? a.transactionDate,
      );
    });
    return payments;
  }

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange:
          _selectedDateRange ??
          DateTimeRange(start: _selectedDate ?? now, end: _selectedDate ?? now),
      helpText: 'Filter ledger by date range',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedDate = picked.start;
      _selectedDateRange = picked;
      _dateFilter = 'date';
    });
  }

  Future<void> _editPayment(PaymentTransaction payment) async {
    final result = await showEditPaymentDialog(
      context,
      amount: payment.amount,
      discount: payment.discount,
      notes: payment.notes,
      method: payment.paymentMethod,
      methodNote: payment.paymentMethodNote,
      transactionDate: payment.transactionDate,
    );
    if (result == null || !mounted) return;
    final success = await TransactionService.updatePayment(
      paymentId: payment.id,
      amount: result.amount,
      discount: result.discount,
      notes: result.notes,
      paymentMethod: result.method,
      paymentMethodNote: result.methodNote,
      transactionDate: result.transactionDate,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Payment updated.'
              : (TransactionService.errorMessage ??
                    'Could not update payment.'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _deletePayment(PaymentTransaction payment) async {
    final colors = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Payment?'),
        content: Text(
          'Delete the payment of ${_money(payment.actualAmountReceived)} actually received from ${payment.customerName}?\n\nThis will restore the customer balance.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete Payment'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success = await TransactionService.deletePayment(payment.id);
    if (!mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment deleted successfully.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await TransactionService.loadTransactions();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            TransactionService.errorMessage ?? 'Could not delete the payment.',
          ),
          backgroundColor: colors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _desktopLedgerHeader(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      color: colors.surfaceContainerHigh,
      child: Row(
        children: [
          const SizedBox(width: 106, child: Text('DATE')),
          const Expanded(flex: 3, child: Text('CUSTOMER')),
          const Expanded(flex: 2, child: Text('ENTERED BY')),
          const SizedBox(width: 180, child: Text('METHOD')),
          const Expanded(flex: 2, child: Text('NOTES')),
          const SizedBox(
            width: 128,
            child: Text('AMOUNT', textAlign: TextAlign.right),
          ),
          const SizedBox(width: 76, child: Text('ACTION')),
        ],
      ),
    );
  }

  Widget _desktopLedgerRow(PaymentTransaction payment, ColorScheme colors) {
    final splitLines = PaymentMethodBreakdown.lines(payment.paymentMethodNote);
    final method = payment.paymentMethod.trim().isEmpty
        ? '—'
        : PaymentMethodBreakdown.methodLabel(payment.paymentMethod);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 106,
            child: Text(
              _formatDate(payment.transactionDate.toLocal()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              payment.customerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              payment.receivedBy,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 180,
            child: splitLines.isEmpty
                ? Text(method, maxLines: 1, overflow: TextOverflow.ellipsis)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in splitLines)
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                    ],
                  ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              payment.notes.trim().isEmpty ? '—' : payment.notes,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
          SizedBox(
            width: 128,
            child: Text(
              _money(_amountForCurrentMethod(payment)),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: colors.primary,
              ),
            ),
          ),
          SizedBox(
            width: 76,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit payment',
                  onPressed: () => _editPayment(payment),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
                IconButton(
                  tooltip: 'Delete payment',
                  onPressed: () => _deletePayment(payment),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: colors.error,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDesktop = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: colors.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text(
          'Payment Ledger',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: colors.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh ledger',
            onPressed: TransactionService.loadTransactions,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: TransactionService.dataVersion,
        builder: (context, version, child) {
          final payments = _filteredPayments();
          final refusedPayments = _filteredRefusedPayments();
          final timeline =
              <
                  ({
                    DateTime at,
                    PaymentTransaction? payment,
                    Map<String, dynamic>? refused,
                  })
                >[
                  ...payments.map(
                    (payment) => (
                      at: payment.transactionDate,
                      payment: payment,
                      refused: null,
                    ),
                  ),
                  ...refusedPayments.map((row) {
                    final parsed =
                        DateTime.tryParse(
                          row['created_at']?.toString() ??
                              '${row['status_date']}T00:00:00',
                        ) ??
                        DateTime.fromMillisecondsSinceEpoch(0);
                    return (at: parsed, payment: null, refused: row);
                  }),
                ]
                ..sort((a, b) => b.at.compareTo(a.at));
          final total = payments.fold<double>(
            0,
            (sum, payment) =>
                sum +
                (_methodFilter == 'all'
                    ? payment.actualAmountReceived
                    : PaymentMethodBreakdown.amountFor(
                        note: payment.paymentMethodNote,
                        method: _methodFilter,
                        fallbackAmount:
                            PaymentMethodBreakdown.parse(
                              payment.paymentMethodNote,
                            ).isEmpty
                            ? payment.actualAmountReceived
                            : 0,
                      )),
          );
          return RefreshIndicator(
            color: colors.primary,
            backgroundColor: colors.surface,
            onRefresh: TransactionService.loadTransactions,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(isDesktop ? 24 : 14),
              children: [
                Text(
                  'A chronological record of customer payments. '
                  'Scroll the table sideways to see all columns.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: isDesktop ? 330 : double.infinity,
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          labelText: 'Search ledger',
                          hintText: 'Customer, method, or note',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: _searchController.clear,
                                  icon: const Icon(Icons.clear_rounded),
                                ),
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: isDesktop ? 190 : 155,
                      child: DropdownButtonFormField<String>(
                        initialValue: _dateFilter,
                        decoration: InputDecoration(
                          labelText: 'Date range',
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('All dates'),
                          ),
                          DropdownMenuItem(
                            value: 'today',
                            child: Text('Today'),
                          ),
                          DropdownMenuItem(
                            value: 'week',
                            child: Text('This week'),
                          ),
                          DropdownMenuItem(
                            value: 'month',
                            child: Text('This month'),
                          ),
                          DropdownMenuItem(
                            value: 'date',
                            child: Text('Choose date range…'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          if (value == 'date') {
                            _chooseDate();
                          } else {
                            setState(() {
                              _dateFilter = value;
                              _selectedDateRange = null;
                              _selectedDate = null;
                            });
                          }
                        },
                      ),
                    ),
                    SizedBox(
                      width: isDesktop ? 180 : 155,
                      child: DropdownButtonFormField<String>(
                        initialValue: _methodFilter,
                        decoration: InputDecoration(
                          labelText: 'Payment method',
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('All methods'),
                          ),
                          DropdownMenuItem(value: 'cash', child: Text('Cash')),
                          DropdownMenuItem(
                            value: 'cheque',
                            child: Text('Cheque'),
                          ),
                          DropdownMenuItem(value: 'neft', child: Text('NEFT')),
                          DropdownMenuItem(value: 'gpay', child: Text('GPay')),
                          DropdownMenuItem(
                            value: 'online',
                            child: Text('Online'),
                          ),
                          DropdownMenuItem(
                            value: 'refused',
                            child: Text('Refused'),
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => _methodFilter = value ?? 'all'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _dateFilter = 'all';
                          _methodFilter = 'all';
                          _selectedDate = null;
                          _selectedDateRange = null;
                        });
                      },
                      icon: const Icon(Icons.filter_alt_off_rounded),
                      label: const Text('Reset'),
                    ),
                    if (_dateFilter == 'date' && _selectedDateRange != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Dates: ${_formatDate(_selectedDateRange!.start)} – ${_formatDate(_selectedDateRange!.end)}',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 620;
                    final statChildren = [
                      _LedgerSummaryItem(
                        label: 'Payments shown',
                        value: '${timeline.length}',
                        icon: Icons.receipt_long_rounded,
                        colors: colors,
                      ),
                      _LedgerSummaryItem(
                        label: 'Total received',
                        value: _money(total),
                        icon: Icons.south_west_rounded,
                        colors: colors,
                      ),
                    ];
                    return compact
                        ? Column(
                            children: [
                              statChildren[0],
                              const SizedBox(height: 10),
                              statChildren[1],
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: statChildren[0]),
                              const SizedBox(width: 12),
                              Expanded(child: statChildren[1]),
                            ],
                          );
                  },
                ),
                const SizedBox(height: 18),
                if (TransactionService.isLoading &&
                    TransactionService.transactions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 90),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (timeline.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(36),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 42,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No ledger entries match these filters',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colors.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Try changing the date range or payment method.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (isDesktop)
                  Card(
                    color: colors.surface,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    child: Column(
                      children: [
                        _desktopLedgerHeader(colors),
                        ...timeline.map(
                          (entry) => entry.payment != null
                              ? _desktopLedgerRow(entry.payment!, colors)
                              : _buildRefusedPaymentCard(
                                  entry.refused!,
                                  colors,
                                ),
                        ),
                      ],
                    ),
                  )
                else
                  ...timeline.map(
                    (entry) => entry.payment != null
                        ? _PaymentTile(
                            payment: entry.payment!,
                            date: _formatDate(
                              entry.payment!.transactionDate.toLocal(),
                            ),
                            displayedReceived: _amountForCurrentMethod(
                              entry.payment!,
                            ),
                            selectedMethod: _methodFilter,
                            colors: colors,
                            onEdit: () => _editPayment(entry.payment!),
                            onHide: () => _hidePayment(entry.payment!),
                            onDelete: () => _deletePayment(entry.payment!),
                          )
                        : _buildRefusedPaymentCard(entry.refused!, colors),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LedgerSummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final ColorScheme colors;

  const _LedgerSummaryItem({
    required this.label,
    required this.value,
    required this.icon,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: colors.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 19,
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

// PAYMENT TILE

// ============================================================

class _PaymentTile extends StatelessWidget {
  final PaymentTransaction payment;

  final String date;

  final double displayedReceived;

  final String selectedMethod;

  final ColorScheme colors;

  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onHide;

  const _PaymentTile({
    required this.payment,

    required this.date,

    required this.displayedReceived,

    required this.selectedMethod,

    required this.colors,

    required this.onDelete,
    required this.onEdit,
    required this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onHide,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),

        padding: const EdgeInsets.all(15),

        decoration: BoxDecoration(
          color: colors.surface,

          borderRadius: BorderRadius.circular(17),

          border: Border.all(color: colors.outlineVariant),
        ),

        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            Container(
              width: 42,

              height: 42,

              decoration: BoxDecoration(
                color: colors.primaryContainer,

                borderRadius: BorderRadius.circular(12),
              ),

              child: Icon(
                Icons.payments_outlined,

                color: colors.onPrimaryContainer,

                size: 20,
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  Text(
                    payment.customerName,

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: TextStyle(
                      color: colors.onSurface,

                      fontSize: 14,

                      fontWeight: FontWeight.w700,
                    ),
                  ),

                  const SizedBox(height: 4),

                  Text(
                    'Received by: ${payment.receivedBy}',

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: TextStyle(
                      color: colors.onSurfaceVariant,

                      fontSize: 11,
                    ),
                  ),

                  const SizedBox(height: 3),
                  Text(
                    '${payment.reference} • Server confirmed',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),

                  const SizedBox(height: 3),

                  Text(
                    date,

                    style: TextStyle(
                      color: colors.onSurfaceVariant,

                      fontSize: 11,
                    ),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    selectedMethod == 'all'
                        ? 'Settlement: ₹${payment.amount.toStringAsFixed(2)}  •  '
                              'Received: ₹${displayedReceived.toStringAsFixed(2)}'
                        : 'Received via ${selectedMethod.toUpperCase()}: '
                              '₹${displayedReceived.toStringAsFixed(2)}',

                    style: TextStyle(
                      color: colors.onSurfaceVariant,

                      fontSize: 10.5,

                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  for (final splitLine in PaymentMethodBreakdown.lines(
                    payment.paymentMethodNote,
                  )) ...[
                    const SizedBox(height: 3),
                    Text(
                      splitLine,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],

                  if (payment.discount > 0) ...[
                    const SizedBox(height: 3),

                    Text(
                      'Discount given: ₹${payment.discount.toStringAsFixed(2)}',

                      style: TextStyle(
                        color: colors.error,

                        fontSize: 10.5,

                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(width: 6),

            PopupMenuButton<String>(
              tooltip: 'Payment actions',

              onSelected: (value) {
                if (value == 'hide') onHide();
                if (value == 'delete') onDelete();
                if (value == 'edit') onEdit();
              },

              itemBuilder: (context) => const [
                PopupMenuItem<String>(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined),
                      SizedBox(width: 10),
                      Text('Edit Payment'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete',

                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded),

                      SizedBox(width: 10),

                      Text('Delete Payment'),
                    ],
                  ),
                ),
              ],

              icon: Icon(
                Icons.more_vert_rounded,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================

// EMPTY PAYMENTS

// ============================================================

class _EmptyPayments extends StatelessWidget {
  final ColorScheme colors;

  final String message;

  const _EmptyPayments({required this.colors})
    : message = 'Payments received from customers will appear here.';

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),

        child: Column(
          mainAxisSize: MainAxisSize.min,

          children: [
            Container(
              width: 70,

              height: 70,

              decoration: BoxDecoration(
                color: colors.primaryContainer,

                shape: BoxShape.circle,
              ),

              child: Icon(
                Icons.payments_outlined,

                color: colors.onPrimaryContainer,

                size: 30,
              ),
            ),

            const SizedBox(height: 16),

            Text(
              'No payments yet',

              style: TextStyle(
                color: colors.onSurface,

                fontSize: 17,

                fontWeight: FontWeight.w800,
              ),
            ),

            const SizedBox(height: 6),

            Text(
              message,

              textAlign: TextAlign.center,

              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================

// REPORTS

// ============================================================

class ReportsPlaceholder extends StatelessWidget {
  const ReportsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const OwnerReportsScreen();
  }
}
