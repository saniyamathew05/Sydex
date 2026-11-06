import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TutorialService {
  TutorialService._();

  static String get _key {
    final userId = Supabase.instance.client.auth.currentUser?.id ?? 'anonymous';
    return 'horizon_hide_tutorial_$userId';
  }

  static Future<bool> shouldShowOnLogin() async {
    final preferences = await SharedPreferences.getInstance();
    return !(preferences.getBool(_key) ?? false);
  }

  static Future<void> setDoNotShowAgain(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_key, value);
  }
}
