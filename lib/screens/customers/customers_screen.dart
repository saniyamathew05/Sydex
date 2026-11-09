import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/customer.dart';
import '../../services/customer_service.dart';
import '../../services/transaction_service.dart';
import '../../services/customer_group_service.dart';
import '../../services/currency_formatter.dart';
import 'add_customer_screen.dart';
import 'customer_details_screen.dart';
import '../payments/payment_screen.dart';
import '../purchases/add_purchase_screen.dart';
import '../../widgets/horizon_motion.dart';

/// Sydex customer directory.
/// Keeps the existing CustomerService and TransactionService data flow.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _locationsScrollController = ScrollController();
  String _searchQuery = '';
  String _selectedLocation = 'All';
  String _balanceFilter = 'All customers';
  String _sort = 'Customer name A–Z';
  double? _minBalance;
  double? _maxBalance;
  List<String> _recentSearches = <String>[];
  List<CustomerGroup> _groups = const [];
  String? _selectedGroupId;
  Set<String> _selectedGroupCustomerIds = const {};

  Color get _green => Theme.of(context).colorScheme.primary;
  Color get _greenBright => Theme.of(context).colorScheme.secondary;
  Color get _page => Theme.of(context).scaffoldBackgroundColor;
  Color get _ink => Theme.of(context).colorScheme.onSurface;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _border => Theme.of(context).colorScheme.outlineVariant;

  @override
  void initState() {
    super.initState();
    _loadRecentSearches();
    _loadGroups();
    _loadData();
    _searchController.addListener(() {
      if (!mounted) return;
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
  }

  Future<void> _loadGroups() async {
    try {
      final groups = await CustomerGroupService.loadGroups();
      if (mounted) setState(() => _groups = groups);
    } catch (_) {
      // Groups are optional; the customer directory remains usable if the
      // migration has not reached an older installation yet.
    }
  }

  Future<void> _selectGroup(String? groupId) async {
    final ids = groupId == null
        ? <String>{}
        : await CustomerGroupService.loadCustomerIds(groupId);
    if (mounted) {
      setState(() {
        _selectedGroupId = groupId;
        _selectedGroupCustomerIds = ids;
      });
    }
  }

  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final searches =
        prefs.getStringList('horizon_recent_customer_searches') ??
        prefs.getStringList('ledgerpro_recent_customer_searches') ??
        <String>[];
    if (!prefs.containsKey('horizon_recent_customer_searches') &&
        searches.isNotEmpty) {
      await prefs.setStringList('horizon_recent_customer_searches', searches);
    }
    if (!mounted) return;
    setState(() => _recentSearches = searches);
  }

  Future<void> _rememberSearch(String value) async {
    final query = value.trim();
    if (query.length < 2) return;
    final next = <String>[
      query,
      ..._recentSearches.where(
        (item) => item.toLowerCase() != query.toLowerCase(),
      ),
    ].take(5).toList();
    setState(() => _recentSearches = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('horizon_recent_customer_searches', next);
  }

  Future<void> _loadData() async {
    await CustomerService.loadCustomers();
    await TransactionService.loadCustomerBalances();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    _locationsScrollController.dispose();
    super.dispose();
  }

  List<String> get _locations {
    final values =
        CustomerService.customers
            .map((c) => c.location.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return ['All', ...values];
  }

  List<Customer> get _filteredCustomers {
    final result = CustomerService.customers.where((customer) {
      final matchesSearch =
          _searchQuery.isEmpty ||
          customer.businessName.toLowerCase().contains(_searchQuery) ||
          customer.location.toLowerCase().contains(_searchQuery) ||
          customer.phone.toLowerCase().contains(_searchQuery) ||
          customer.id.toLowerCase().contains(_searchQuery);
      final matchesLocation =
          _selectedLocation == 'All' ||
          customer.location.trim().toLowerCase() ==
              _selectedLocation.toLowerCase();
      final matchesGroup =
          _selectedGroupId == null ||
          _selectedGroupCustomerIds.contains(customer.id);
      final balance = TransactionService.getCustomerBalance(customer.id);
      final matchesBalance =
          switch (_balanceFilter) {
            'Outstanding balance' => balance > 0,
            'Zero balance' => balance == 0,
            'Customer credit' => balance < 0,
            _ => true,
          } &&
          (_minBalance == null || balance >= _minBalance!) &&
          (_maxBalance == null || balance <= _maxBalance!);
      return matchesSearch && matchesLocation && matchesGroup && matchesBalance;
    }).toList();
    result.sort((a, b) {
      final ab = TransactionService.getCustomerBalance(a.id);
      final bb = TransactionService.getCustomerBalance(b.id);
      return switch (_sort) {
        'Customer name Z–A' => b.businessName.toLowerCase().compareTo(
          a.businessName.toLowerCase(),
        ),
        'Highest outstanding balance' => bb.compareTo(ab),
        'Lowest outstanding balance' => ab.compareTo(bb),
        'Most recent payment' =>
          _lastPaymentDate(b)?.compareTo(
                _lastPaymentDate(a) ?? DateTime.fromMillisecondsSinceEpoch(0),
              ) ??
              -1,
        'Oldest payment' =>
          (_lastPaymentDate(a) ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(
                _lastPaymentDate(b) ?? DateTime.fromMillisecondsSinceEpoch(0),
              ),
        _ => a.businessName.toLowerCase().compareTo(
          b.businessName.toLowerCase(),
        ),
      };
    });
    return result;
  }

  DateTime? _lastPaymentDate(Customer customer) {
    final payments = TransactionService.transactions.where(
      (t) =>
          t.customerId == customer.id &&
          t.transactionType == 'payment_received' &&
          !t.isBounced,
    );
    if (payments.isEmpty) return null;
    return payments
        .map((t) => t.transactionDate)
        .reduce((a, b) => a.isAfter(b) ? a : b);
  }

  String _lastPayment(Customer customer) {
    final payments =
        TransactionService.transactions
            .where(
              (t) =>
                  t.customerId == customer.id &&
                  t.transactionType == 'payment_received' &&
                  !t.isBounced,
            )
            .toList()
          ..sort((a, b) => b.transactionDate.compareTo(a.transactionDate));
    return payments.isEmpty
        ? 'No payments yet'
        : '${_formatDate(payments.first.transactionDate)} • ${CurrencyFormatter.rupees(payments.first.actualAmountReceived)}';
  }

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  Future<void> _addCustomer() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddCustomerScreen()),
    );
    if (result == true) await _loadData();
  }

  Future<void> _openCustomer(Customer customer) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerDetailsScreen(customer: customer),
      ),
    );
    await _loadData();
  }

  Future<void> _deleteCustomer(Customer customer) async {
    final confirmationController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Permanently delete customer?'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This permanently removes "${customer.businessName}" and all of their purchases, payments, ledger history, route and visit records, group memberships, and saved signatures.',
                ),
                const SizedBox(height: 16),
                const Text('Type DELETE to confirm.'),
                const SizedBox(height: 8),
                TextField(
                  controller: confirmationController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(hintText: 'DELETE'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed:
                  confirmationController.text.trim().toUpperCase() == 'DELETE'
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      ),
    );
    confirmationController.dispose();
    if (confirmed != true) return;

    final result = await CustomerService.deleteCustomer(customer.id);
    if (!mounted) return;
    if (!result.deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            CustomerService.errorMessage ?? 'Could not delete customer.',
          ),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${customer.businessName} and all related data were permanently deleted.',
        ),
      ),
    );
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark
        ? Theme.of(context).scaffoldBackgroundColor
        : _page;
    final surface = Theme.of(context).colorScheme.surface;
    final foreground = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: surface,
        foregroundColor: foreground,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: Text(
          'Customers',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 21,
            letterSpacing: -0.4,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: _addCustomer,
              style: FilledButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: Text(
                'Add Customer',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: _greenBright,
        onRefresh: _loadData,
        child: ValueListenableBuilder<int>(
          valueListenable: CustomerService.dataVersion,
          builder: (context, _, _) => ValueListenableBuilder<int>(
            valueListenable: TransactionService.dataVersion,
            builder: (context, _, _) {
              final customers = _filteredCustomers;
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                    child: Column(
                      children: [
                        TextField(
                          controller: _searchController,
                          onSubmitted: _rememberSearch,
                          style: TextStyle(color: foreground, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Search by name, phone or location...',
                            hintStyle: TextStyle(color: _muted, fontSize: 13),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: _muted,
                              size: 21,
                            ),
                            suffixIcon: _searchQuery.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: _searchController.clear,
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                            filled: true,
                            fillColor: surface,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 14,
                              horizontal: 14,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: _border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: _green, width: 1.4),
                            ),
                          ),
                        ),
                        if (_searchQuery.isEmpty &&
                            _recentSearches.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: 6,
                              children: _recentSearches
                                  .map(
                                    (query) => ActionChip(
                                      label: Text(
                                        query,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      onPressed: () {
                                        _searchController.text = query;
                                        _searchController.selection =
                                            TextSelection.collapsed(
                                              offset: query.length,
                                            );
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 42,
                    child: Scrollbar(
                      controller: _locationsScrollController,
                      thumbVisibility: true,
                      trackVisibility: true,
                      thickness: 7,
                      radius: const Radius.circular(8),
                      child: ListView.separated(
                        controller: _locationsScrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 4,
                        ),
                        scrollDirection: Axis.horizontal,
                        itemCount: _locations.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final location = _locations[index];
                          final selected = location == _selectedLocation;
                          final count = location == 'All'
                              ? CustomerService.customers.length
                              : CustomerService.customers
                                    .where(
                                      (c) =>
                                          c.location.trim().toLowerCase() ==
                                          location.toLowerCase(),
                                    )
                                    .length;
                          return ChoiceChip(
                            selected: selected,
                            showCheckmark: false,
                            label: Text('$location ($count)'),
                            labelStyle: TextStyle(
                              color: selected ? Colors.white : _ink,
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                            selectedColor: _greenBright,
                            backgroundColor: surface,
                            side: BorderSide(
                              color: selected ? _greenBright : _border,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            onSelected: (_) =>
                                setState(() => _selectedLocation = location),
                          );
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _filterDropdown(
                                'Balance',
                                _balanceFilter,
                                const [
                                  'All customers',
                                  'Outstanding balance',
                                  'Zero balance',
                                  'Customer credit',
                                ],
                                (v) => setState(() => _balanceFilter = v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _filterDropdown('Sort', _sort, const [
                                'Customer name A–Z',
                                'Customer name Z–A',
                                'Highest outstanding balance',
                                'Lowest outstanding balance',
                                'Most recent payment',
                                'Oldest payment',
                              ], (v) => setState(() => _sort = v)),
                            ),
                          ],
                        ),
                        if (_groups.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String?>(
                            value: _selectedGroupId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Customer group',
                              prefixIcon: Icon(Icons.folder_outlined),
                            ),
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('All customer groups'),
                              ),
                              ..._groups.map(
                                (group) => DropdownMenuItem<String?>(
                                  value: group.id,
                                  child: Text(group.name),
                                ),
                              ),
                            ],
                            onChanged: _selectGroup,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  Expanded(
                    child: customers.isEmpty
                        ? _EmptyCustomers(
                            hasSearch:
                                _searchQuery.isNotEmpty ||
                                _selectedLocation != 'All' ||
                                _selectedGroupId != null,
                          )
                        : Column(
                            children: [
                              if (MediaQuery.sizeOf(context).width >= 900)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    22,
                                    8,
                                    22,
                                    4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'CUSTOMER',
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 205,
                                        child: Text(
                                          'LAST PAYMENT',
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 125,
                                        child: Text(
                                          'BALANCE',
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 64),
                                    ],
                                  ),
                                ),
                              if (MediaQuery.sizeOf(context).width >= 900)
                                Divider(
                                  height: 1,
                                  color: isDark ? Colors.white12 : _border,
                                ),
                              Expanded(
                                child: ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    24,
                                  ),
                                  itemCount: customers.length,
                                  separatorBuilder: (_, _) => Divider(
                                    height: 1,
                                    color: isDark ? Colors.white12 : _border,
                                    indent: 58,
                                  ),
                                  itemBuilder: (context, index) {
                                    final customer = customers[index];
                                    final balance =
                                        TransactionService.getCustomerBalance(
                                          customer.id,
                                        );
                                    return HorizonFadeSlide(
                                      delay: Duration(
                                        milliseconds: (index.clamp(0, 8)) * 18,
                                      ),
                                      child: _CustomerRow(
                                        customer: customer,
                                        balance: balance,
                                        lastPayment: _lastPayment(customer),
                                        onTap: () => _openCustomer(customer),
                                        onDelete: () =>
                                            _deleteCustomer(customer),
                                        onPayment: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => PaymentScreen(
                                              customer: customer,
                                            ),
                                          ),
                                        ),
                                        onPurchase: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => AddPurchaseScreen(
                                              initialCustomer: customer,
                                            ),
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
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _filterDropdown(
    String label,
    String value,
    List<String> values,
    ValueChanged<String> onChanged,
  ) => DropdownButtonFormField<String>(
    value: value,
    isDense: true,
    decoration: InputDecoration(
      labelText: label,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    ),
    items: values
        .map(
          (v) => DropdownMenuItem(
            value: v,
            child: Text(v, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );
}

class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    required this.customer,
    required this.balance,
    required this.lastPayment,
    required this.onTap,
    required this.onDelete,
    required this.onPayment,
    required this.onPurchase,
  });

  final Customer customer;
  final double balance;
  final String lastPayment;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onPayment;
  final VoidCallback onPurchase;

  String _money(double amount) => CurrencyFormatter.rupees(amount, decimals: 0);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final initials = customer.businessName.trim().isEmpty
        ? '?'
        : customer.businessName
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((p) => p[0])
              .join()
              .toUpperCase();
    final due = balance > 0;
    return Material(
      color: surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: isDark
                        ? const [Color(0xFF155A3A), Color(0xFF123023)]
                        : const [Color(0xFFDDF3E5), Color(0xFFC9E5D1)],
                  ),
                ),
                child: Text(
                  initials,
                  style: TextStyle(
                    color: primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
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
                        color: foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 13,
                          color: muted,
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            customer.location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted, fontSize: 11),
                          ),
                        ),
                        Text(
                          '  ·  ',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                        Flexible(
                          child: Text(
                            customer.phone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (desktop) ...[
                const SizedBox(width: 18),
                SizedBox(
                  width: 205,
                  child: Text(
                    lastPayment,
                    style: TextStyle(color: muted, fontSize: 10),
                    maxLines: 2,
                  ),
                ),
                const SizedBox(width: 18),
              ],
              if (!desktop) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: Text(
                    lastPayment,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
                ),
              ],
              SizedBox(
                width: desktop ? 125 : null,
                child: Text(
                  balance < 0
                      ? 'To give ${_money(balance.abs())}'
                      : _money(balance),
                  textAlign: desktop ? TextAlign.right : TextAlign.left,
                  style: TextStyle(
                    color: due ? scheme.error : scheme.tertiary,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
              if (!desktop) const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: 'Customer options',
                icon: Icon(Icons.more_vert_rounded, size: 19, color: muted),
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                  if (value == 'view') onTap();
                  if (value == 'payment') onPayment();
                  if (value == 'purchase') onPurchase();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'view', child: Text('View customer')),
                  PopupMenuItem(
                    value: 'payment',
                    child: Text('Record payment'),
                  ),
                  PopupMenuItem(
                    value: 'purchase',
                    child: Text('Record new purchase'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Remove customer'),
                  ),
                ],
              ),
              Icon(Icons.chevron_right_rounded, color: muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCustomers extends StatelessWidget {
  const _EmptyCustomers({required this.hasSearch});
  final bool hasSearch;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 90),
        Icon(
          Icons.people_outline_rounded,
          size: 54,
          color: color.withValues(alpha: 0.35),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            hasSearch ? 'No matching customers' : 'No customers yet',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            hasSearch
                ? 'Try another name, phone number or location.'
                : 'Add your first customer to get started.',
            style: TextStyle(
              color: color.withValues(alpha: 0.65),
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}
