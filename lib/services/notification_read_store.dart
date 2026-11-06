import 'package:shared_preferences/shared_preferences.dart';

class NotificationReadStore {
  NotificationReadStore._();
  static const _key = 'horizon_seen_notification_ids';
  static const _legacyKey = 'ledgerpro_seen_notification_ids';

  static Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final seen =
        prefs.getStringList(_key) ??
        prefs.getStringList(_legacyKey) ??
        const <String>[];
    if (!prefs.containsKey(_key) && seen.isNotEmpty) {
      await prefs.setStringList(_key, seen);
    }
    return seen.toSet();
  }

  static Future<void> markSeen(Iterable<String> ids) async {
    final seen = await load();
    seen.addAll(ids.where((id) => id.trim().isNotEmpty));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, seen.toList());
  }
}
