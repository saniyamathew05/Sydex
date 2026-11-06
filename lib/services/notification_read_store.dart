import 'package:shared_preferences/shared_preferences.dart';

class NotificationReadStore {
  NotificationReadStore._();
  static const _key = 'ledgerpro_seen_notification_ids';

  static Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  static Future<void> markSeen(Iterable<String> ids) async {
    final seen = await load();
    seen.addAll(ids.where((id) => id.trim().isNotEmpty));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, seen.toList());
  }
}
