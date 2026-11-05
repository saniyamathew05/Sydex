import 'package:flutter/material.dart';

import '../../models/customer.dart';
import '../../services/customer_service.dart';
import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import 'add_customer_screen.dart';
import 'customer_details_screen.dart';

/// LedgerPro customer directory styled to match the supplied reference mockup.
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

  static const _green = Color(0xFF0B5D3B);
  static const _greenBright = Color(0xFF149A5A);
  Color get _page => Theme.of(context).scaffoldBackgroundColor;
  Color get _ink => Theme.of(context).colorScheme.onSurface;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _border => Theme.of(context).colorScheme.outlineVariant;

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(() {
      if (!mounted) return;
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
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
    return CustomerService.customers.where((customer) {
      final matchesSearch =
          _searchQuery.isEmpty ||
          customer.businessName.toLowerCase().contains(_searchQuery) ||
          customer.location.toLowerCase().contains(_searchQuery) ||
          customer.phone.toLowerCase().contains(_searchQuery);
      final matchesLocation =
          _selectedLocation == 'All' ||
          customer.location.trim().toLowerCase() ==
              _selectedLocation.toLowerCase();
      return matchesSearch && matchesLocation;
    }).toList();
  }

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove customer?'),
        content: Text(
          'Remove "${customer.businessName}" from the active customer list? Purchase and payment history will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _green),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final success = await CustomerService.deleteCustomer(customer.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? '${customer.businessName} was removed.'
              : CustomerService.errorMessage ?? 'Could not remove customer.',
        ),
      ),
    );
    if (success) await _loadData();
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
                    child: TextField(
                      controller: _searchController,
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
                  const SizedBox(height: 5),
                  Expanded(
                    child: customers.isEmpty
                        ? _EmptyCustomers(
                            hasSearch:
                                _searchQuery.isNotEmpty ||
                                _selectedLocation != 'All',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
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
                              return _CustomerRow(
                                customer: customer,
                                balance: balance,
                                onTap: () => _openCustomer(customer),
                                onDelete: () => _deleteCustomer(customer),
                              );
                            },
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
}

class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    required this.customer,
    required this.balance,
    required this.onTap,
    required this.onDelete,
  });

  final Customer customer;
  final double balance;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  static const _green = Color(0xFF0B5D3B);
  String _money(double amount) => CurrencyFormatter.rupees(amount, decimals: 0);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final scheme = Theme.of(context).colorScheme;
    final surface = Theme.of(context).colorScheme.surface;
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
                    color: _green,
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
              const SizedBox(width: 8),
              Text(
                balance < 0
                    ? 'To give ${_money(balance.abs())}'
                    : _money(balance),
                style: TextStyle(
                  color: due ? scheme.error : scheme.tertiary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Customer options',
                icon: Icon(Icons.more_vert_rounded, size: 19, color: muted),
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
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
