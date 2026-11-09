import 'package:supabase_flutter/supabase_flutter.dart';

/// Looks up names for users who have recorded a payment or ledger entry.
class LedgerUserNameService {
  LedgerUserNameService._();

  static Future<Map<String, String>> loadNames(Iterable<String?> userIds) async {
    final ids = userIds
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return <String, String>{};

    final rows = await Supabase.instance.client.rpc(
      'get_payment_receiver_names',
      params: {'p_user_ids': ids},
    );
    final names = <String, String>{};
    for (final row in rows as List) {
      final id = row['user_id']?.toString();
      final name = row['name']?.toString().trim();
      if (id != null && name != null && name.isNotEmpty) names[id] = name;
    }
    return names;
  }
}
