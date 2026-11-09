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

extension HorizonGuideProgress on TutorialService {
  static String _progressKey(String suffix) {
    final userId = Supabase.instance.client.auth.currentUser?.id ?? 'anonymous';
    return 'horizon_guide_${suffix}_$userId';
  }

  static Future<Set<String>> completedLessons() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getStringList(_progressKey('completed'))?.toSet() ??
        <String>{};
  }

  static Future<void> setLessonCompleted(
    String lessonId,
    bool completed,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final lessons = await completedLessons();
    completed ? lessons.add(lessonId) : lessons.remove(lessonId);
    await preferences.setStringList(
      _progressKey('completed'),
      lessons.toList(),
    );
  }

  static Future<void> markOpened(String lessonId) async {
    final preferences = await SharedPreferences.getInstance();
    final current =
        preferences.getStringList(_progressKey('recent')) ?? <String>[];
    current.remove(lessonId);
    current.insert(0, lessonId);
    await preferences.setStringList(
      _progressKey('recent'),
      current.take(6).toList(),
    );
  }

  static Future<List<String>> recentLessons() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getStringList(_progressKey('recent')) ?? <String>[];
  }
}
