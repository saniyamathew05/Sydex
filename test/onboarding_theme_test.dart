import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sydex/screens/onboarding/onboarding_screen.dart';
import 'package:sydex/services/theme_controller.dart';
import 'package:sydex/theme/sydex_theme.dart';
import 'package:sydex/theme/workspace_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    for (final accent in ThemeController.accentChoices.values) {
      test('theme builds for $brightness / $accent', () {
        final theme = workspaceTheme(buildSydexTheme(brightness, accent));
        expect(theme.colorScheme.brightness, brightness);
        expect(theme.colorScheme.onPrimary, isNot(theme.colorScheme.primary));
      });
    }
  }

  testWidgets('tour walks through every step and finishes', (tester) async {
    await OnboardingStore.load();
    expect(OnboardingStore.seen.value, isFalse);
    var finished = false;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSydexTheme(Brightness.light, SydexColors.ink),
        home: OnboardingScreen(onFinished: () => finished = true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your whole ledger in one place.'), findsOneWidget);

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Private by design.'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(OnboardingStore.seen.value, isTrue);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('tour renders in dark mode without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSydexTheme(Brightness.dark, SydexColors.ink),
        home: OnboardingScreen(onFinished: () {}),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (i < 4) await tester.tap(find.text('Continue'));
    }
    await tester.binding.setSurfaceSize(null);
  });
}
