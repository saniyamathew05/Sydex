import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/indian_currency_input_formatter.dart';
import '../../models/customer.dart';
import '../../services/customer_service.dart';
import 'customer_details_screen.dart';

class AddCustomerScreen extends StatefulWidget {
  const AddCustomerScreen({super.key});

  @override
  State<AddCustomerScreen> createState() => _AddCustomerScreenState();
}

class _AddCustomerScreenState extends State<AddCustomerScreen> {
  final businessNameController = TextEditingController();

  final locationController = TextEditingController();

  final phoneController = TextEditingController();

  final openingBalanceController = TextEditingController();
  final _businessNameFocus = FocusNode();
  final _locationFocus = FocusNode();
  final _phoneFocus = FocusNode();
  final _openingBalanceFocus = FocusNode();

  bool isSaving = false;
  bool _whatsAppReceiptOptIn = false;

  List<Customer> _similarCustomers = const [];

  List<String> _suggestedLocations = const [];
  List<Map<String, dynamic>> _routeTemplates = const [];
  final Set<String> _selectedRouteIds = <String>{};

  final SupabaseClient supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    businessNameController.addListener(_updateSuggestions);
    locationController.addListener(_updateSuggestions);
    CustomerService.dataVersion.addListener(_updateSuggestions);
    _updateSuggestions();
    _loadRouteTemplates();
  }

  Future<void> _loadRouteTemplates() async {
    try {
      final rows = await supabase
          .from('salesman_route_templates')
          .select('id, route_name, locations')
          .order('route_name');
      if (!mounted) return;
      setState(() => _routeTemplates = List<Map<String, dynamic>>.from(rows));
    } catch (error) {
      debugPrint('Could not load route templates: $error');
    }
  }

  Future<void> _selectRoutes() async {
    final selected = Set<String>.from(_selectedRouteIds);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Assign to routes'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _routeTemplates.map((route) {
                  final id = route['id'].toString();
                  return CheckboxListTile(
                    dense: true,
                    value: selected.contains(id),
                    title: Text(route['route_name']?.toString() ?? 'Route'),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(id);
                      } else {
                        selected.remove(id);
                      }
                    }),
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                setState(() {
                  _selectedRouteIds
                    ..clear()
                    ..addAll(selected);
                });
                Navigator.pop(dialogContext);
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  List<String> get _selectedRouteLocations {
    final locations = <String>{};
    for (final route in _routeTemplates) {
      if (!_selectedRouteIds.contains(route['id']?.toString())) continue;
      final values = route['locations'];
      if (values is List) {
        locations.addAll(values.map((item) => item.toString()));
      }
    }
    return locations.toList()..sort();
  }

  @override
  void dispose() {
    businessNameController.removeListener(_updateSuggestions);
    locationController.removeListener(_updateSuggestions);
    CustomerService.dataVersion.removeListener(_updateSuggestions);
    businessNameController.dispose();
    locationController.dispose();
    phoneController.dispose();
    openingBalanceController.dispose();
    _businessNameFocus.dispose();
    _locationFocus.dispose();
    _phoneFocus.dispose();
    _openingBalanceFocus.dispose();
    super.dispose();
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  double _similarity(String first, String second) {
    if (first.isEmpty || second.isEmpty) return 0;
    final previous = List<int>.generate(second.length + 1, (i) => i);
    for (var i = 0; i < first.length; i++) {
      var diagonal = previous[0];
      previous[0] = i + 1;
      for (var j = 0; j < second.length; j++) {
        final above = previous[j + 1];
        final cost = first[i] == second[j] ? 0 : 1;
        previous[j + 1] = [
          previous[j] + 1,
          above + 1,
          diagonal + cost,
        ].reduce((a, b) => a < b ? a : b);
        diagonal = above;
      }
    }
    final distance = previous[second.length];
    final length = first.length > second.length ? first.length : second.length;
    return 1 - distance / length;
  }

  double _customerNameScore(String query, Customer customer) {
    final name = _normalize(customer.businessName);
    final prefixLength = query.length < name.length
        ? query.length
        : name.length;
    final prefix = name.substring(0, prefixLength);
    var score = _similarity(query, name);
    score = score > _similarity(query, prefix)
        ? score
        : _similarity(query, prefix);

    final queryWords = businessNameController.text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty);
    final nameWords = customer.businessName
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (queryWords.isNotEmpty && nameWords.isNotEmpty) {
      var total = 0.0;
      for (final word in queryWords) {
        final wordScore = nameWords
            .map((candidate) {
              if (candidate.startsWith(word)) return 1.0;
              return _similarity(word, candidate);
            })
            .reduce((a, b) => a > b ? a : b);
        total += wordScore;
      }
      final wordScore = total / queryWords.length;
      if (wordScore > score) score = wordScore;
    }
    return score;
  }

  void _updateSuggestions() {
    if (!mounted) return;
    final query = _normalize(businessNameController.text.trim());
    final customers = CustomerService.customers.toList();
    if (query.length >= 2) {
      customers.removeWhere((customer) {
        final name = _normalize(customer.businessName);
        return !name.contains(query) &&
            _customerNameScore(query, customer) < 0.68;
      });
      customers.sort(
        (a, b) => _customerNameScore(
          query,
          b,
        ).compareTo(_customerNameScore(query, a)),
      );
    } else {
      customers.clear();
    }

    final locationQuery = _normalize(locationController.text.trim());
    final locations =
        CustomerService.customers
            .map((customer) => customer.location.trim())
            .where((location) => location.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final matchingLocations = locations
        .where((location) {
          return locationQuery.isEmpty ||
              _normalize(location).contains(locationQuery);
        })
        .take(8)
        .toList();

    if (!mounted) {
      _similarCustomers = customers.take(5).toList();
      _suggestedLocations = matchingLocations;
      return;
    }
    setState(() {
      _similarCustomers = customers.take(5).toList();
      _suggestedLocations = matchingLocations;
    });
  }

  Widget _buildSimilarCustomerSuggestions(ColorScheme colors) {
    if (_similarCustomers.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.tertiary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: colors.tertiary,
              ),
              const SizedBox(width: 7),
              Text(
                'Similar customers already exist',
                style: TextStyle(
                  color: colors.onTertiaryContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Check these records before creating another customer.',
            style: TextStyle(color: colors.onTertiaryContainer, fontSize: 12),
          ),
          const SizedBox(height: 7),
          ..._similarCustomers.map(
            (customer) => Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Material(
                color: colors.surface,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openSimilarCustomer(customer),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.storefront_outlined,
                          size: 16,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${customer.businessName} · ${customer.location}'
                            '${customer.phone.trim().isEmpty ? '' : ' · ${customer.phone}'}',
                            style: TextStyle(
                              color: colors.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _openSimilarCustomer(customer),
                          icon: const Icon(Icons.open_in_new_rounded, size: 15),
                          label: const Text('Select'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSimilarCustomer(Customer customer) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CustomerDetailsScreen(customer: customer),
      ),
    );
  }

  Widget _buildLocationSuggestions(ColorScheme colors) {
    if (_suggestedLocations.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose an existing location',
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _suggestedLocations.map((location) {
              return ActionChip(
                avatar: const Icon(Icons.location_on_outlined, size: 16),
                label: Text(location),
                onPressed: () {
                  locationController.value = TextEditingValue(
                    text: location,
                    selection: TextSelection.collapsed(offset: location.length),
                  );
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDuplicateCustomer(
    String businessName,
    String location,
  ) async {
    final duplicates = CustomerService.customers.where((customer) {
      return _normalize(customer.businessName) == _normalize(businessName) &&
          _normalize(customer.location) == _normalize(location);
    }).toList();
    if (duplicates.isEmpty) return true;
    final duplicate = duplicates.first;

    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Customer may already exist'),
            content: Text(
              '${duplicate.businessName} is already listed in ${duplicate.location}. '
              'Do you still want to create another record?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Create anyway'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> saveCustomer() async {
    final businessName = businessNameController.text.trim();

    final location = locationController.text.trim();

    final phone = phoneController.text.trim();

    final openingBalance =
        double.tryParse(
          openingBalanceController.text.trim().replaceAll(',', ''),
        ) ??
        0;

    if (businessName.isEmpty || location.isEmpty) {
      _showMessage('Please fill in all required fields.');
      return;
    }

    if (openingBalance < 0) {
      _showMessage('Opening balance cannot be negative.');
      return;
    }

    if (phone.isNotEmpty && phone.length != 10) {
      _showMessage('Please enter a valid 10-digit phone number.');
      return;
    }

    if (!await _confirmDuplicateCustomer(businessName, location)) return;

    setState(() {
      isSaving = true;
    });

    try {
      final user = supabase.auth.currentUser;

      if (user == null) {
        throw Exception('You are not logged in to Supabase.');
      }

      final profile = await supabase
          .from('profiles')
          .select('id, name, role, company_id')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        throw Exception('No profile was found for the logged-in user.');
      }

      if (profile['role'] != 'owner') {
        throw Exception('Your account is not an owner account.');
      }

      final companyId = profile['company_id']?.toString();
      if (companyId == null || companyId.isEmpty) {
        throw Exception(
          'Your account is not linked to a company. Sign out and sign back in, then try again.',
        );
      }

      await supabase.from('customers').insert({
        'company_id': companyId,
        'business_name': businessName,
        'location': location,
        'phone': phone,
        'whatsapp_receipt_opt_in': _whatsAppReceiptOptIn,
        'opening_balance': openingBalance,
        'is_active': true,
      });

      if (!mounted) return;

      _showMessage('Customer saved successfully.');

      Navigator.pop(context, true);
    } on PostgrestException catch (error) {
      debugPrint('SUPABASE ERROR: ${error.message}');

      if (!mounted) return;

      _showMessage(
        'Supabase error:\n'
        '${error.message}\n'
        'Code: ${error.code}',
      );
    } catch (error) {
      debugPrint('GENERAL ERROR: $error');

      if (!mounted) return;

      _showMessage('Error:\n$error');
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,

      appBar: AppBar(
        title: const Text(
          'Add Customer',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.person_add_alt_1_outlined,
                      color: colorScheme.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 9),
                    const Text(
                      'Add Customer',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Create a new customer account',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const Divider(height: 24),

                const Text(
                  'Customer Information',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),

                const SizedBox(height: 6),

                Text(
                  'Enter the basic details of the business.',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 12),

                _FormField(
                  controller: businessNameController,
                  focusNode: _businessNameFocus,
                  nextFocusNode: _locationFocus,
                  label: 'Business Name',
                  hint: 'e.g. ABC Traders',
                  icon: Icons.storefront_outlined,
                  textCapitalization: TextCapitalization.words,
                ),

                _buildSimilarCustomerSuggestions(colorScheme),

                const SizedBox(height: 10),

                _FormField(
                  controller: locationController,
                  focusNode: _locationFocus,
                  nextFocusNode: _phoneFocus,
                  label: 'Location',
                  hint: 'e.g. Kuttikanam',
                  icon: Icons.location_on_outlined,
                  textCapitalization: TextCapitalization.words,
                ),

                _buildLocationSuggestions(colorScheme),

                if (_routeTemplates.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: _selectRoutes,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Assign to routes (optional)',
                        prefixIcon: Icon(Icons.alt_route_rounded),
                        suffixIcon: Icon(Icons.arrow_drop_down),
                        border: OutlineInputBorder(),
                      ),
                      child: Text(
                        _selectedRouteIds.isEmpty
                            ? 'No routes selected'
                            : _routeTemplates
                                  .where(
                                    (route) => _selectedRouteIds.contains(
                                      route['id']?.toString(),
                                    ),
                                  )
                                  .map(
                                    (route) =>
                                        route['route_name']?.toString() ??
                                        'Route',
                                  )
                                  .join(', '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (_selectedRouteIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: _routeTemplates
                            .where(
                              (route) => _selectedRouteIds.contains(
                                route['id']?.toString(),
                              ),
                            )
                            .map(
                              (route) => InputChip(
                                label: Text(
                                  route['route_name']?.toString() ?? 'Route',
                                ),
                                onDeleted: () => setState(
                                  () => _selectedRouteIds.remove(
                                    route['id']?.toString(),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  if (_selectedRouteIds.isNotEmpty &&
                      _selectedRouteLocations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue:
                          _selectedRouteLocations.contains(
                            locationController.text.trim(),
                          )
                          ? locationController.text.trim()
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Location in selected routes',
                        prefixIcon: Icon(Icons.location_on_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: _selectedRouteLocations
                          .map(
                            (location) => DropdownMenuItem(
                              value: location,
                              child: Text(location),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        locationController.text = value;
                      },
                    ),
                  ],
                ],

                const SizedBox(height: 14),

                _FormField(
                  controller: phoneController,
                  focusNode: _phoneFocus,
                  nextFocusNode: _openingBalanceFocus,
                  label: 'Phone Number (Optional)',
                  hint: 'e.g. 9876543210',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  maxLength: 10,
                ),

                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _whatsAppReceiptOptIn,
                  onChanged: phoneController.text.trim().isEmpty
                      ? null
                      : (value) => setState(
                            () => _whatsAppReceiptOptIn = value ?? false,
                          ),
                  title: const Text('Send payment receipts on WhatsApp'),
                  subtitle: const Text(
                    'Select only after the customer agrees to receive payment receipts on this number.',
                  ),
                ),

                const SizedBox(height: 18),

                const Text(
                  'Account Information',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),

                const SizedBox(height: 6),

                Text(
                  'Set the amount currently owed by the customer.',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 12),

                _FormField(
                  controller: openingBalanceController,
                  focusNode: _openingBalanceFocus,
                  onSubmitted: saveCustomer,
                  label: 'Opening Balance',
                  hint: 'e.g. 5000',
                  icon: Icons.account_balance_wallet_outlined,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: const [IndianCurrencyInputFormatter()],
                  prefixText: '₹ ',
                ),

                const SizedBox(height: 10),

                Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Opening balance is the amount the customer already owes before any new payments or purchases are recorded.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: isSaving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: isSaving ? null : saveCustomer,
                      icon: isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_rounded, size: 18),
                      label: Text(
                        isSaving ? 'Saving...' : 'Create Customer',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                Center(
                  child: Text(
                    'Customer information is securely saved to your business database.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final FocusNode? nextFocusNode;
  final VoidCallback? onSubmitted;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int? maxLength;
  final String? prefixText;
  final List<TextInputFormatter>? inputFormatters;

  const _FormField({
    required this.controller,
    required this.focusNode,
    this.nextFocusNode,
    this.onSubmitted,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.maxLength,
    this.prefixText,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return TextField(
      controller: controller,
      focusNode: focusNode,
      textInputAction: nextFocusNode == null
          ? TextInputAction.done
          : TextInputAction.next,
      onSubmitted: (_) {
        if (nextFocusNode != null) {
          FocusScope.of(context).requestFocus(nextFocusNode);
        } else {
          onSubmitted?.call();
        }
      },
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textCapitalization: textCapitalization,
      maxLength: maxLength,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        prefixText: prefixText,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        counterText: maxLength != null ? null : '',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.08),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
    );
  }
}
