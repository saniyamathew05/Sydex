import 'package:supabase_flutter/supabase_flutter.dart';

class CustomerGroup {
  const CustomerGroup({
    required this.id,
    required this.name,
    required this.isArchived,
  });

  final String id;
  final String name;
  final bool isArchived;

  factory CustomerGroup.fromMap(Map<String, dynamic> row) => CustomerGroup(
        id: row['id'].toString(),
        name: row['name']?.toString() ?? '',
        isArchived: row['is_archived'] == true,
      );
}

/// Tenant-scoped customer group access. Group data never changes ledger rows.
class CustomerGroupService {
  CustomerGroupService._();

  static final _client = Supabase.instance.client;

  static Future<List<CustomerGroup>> loadGroups({bool includeArchived = false}) async {
    var query = _client.from('customer_groups').select('id, name, is_archived');
    if (!includeArchived) query = query.eq('is_archived', false);
    final rows = await query.order('name');
    return rows
        .map((row) => CustomerGroup.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  static Future<Set<String>> loadCustomerIds(String groupId) async {
    final rows = await _client
        .from('customer_group_members')
        .select('customer_id')
        .eq('group_id', groupId);
    return rows.map((row) => row['customer_id'].toString()).toSet();
  }
}
