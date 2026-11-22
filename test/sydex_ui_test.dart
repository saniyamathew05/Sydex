import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sydex/screens/owner/owner_notifications_screen.dart';
import 'package:sydex/theme/sydex_theme.dart';
import 'package:sydex/widgets/sydex_ui.dart';

Widget _app(Brightness brightness, Widget home) => MaterialApp(
  theme: buildSydexTheme(brightness, SydexColors.ink),
  home: home,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    testWidgets('layout kit renders on a phone ($brightness)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      var tapped = 0;
      await tester.pumpWidget(
        _app(
          brightness,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                SydexScreenHeader(
                  eyebrow: 'Sunday, 22 Nov',
                  title: 'Good morning, a very long business owner name',
                  leading: const SydexAvatar('Saniya Mathew'),
                  actions: [
                    SydexIconButton(
                      icon: Icons.notifications_none_rounded,
                      tooltip: 'Notifications',
                      onPressed: () => tapped++,
                      badgeCount: 120,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SydexChoiceChips(
                  options: const ['Today', 'This week', 'This month', 'Custom'],
                  selected: 'Today',
                  onSelected: (_) => tapped++,
                ),
                const SizedBox(height: 12),
                const SydexHeroCard(
                  child: Column(
                    children: [
                      SydexMiniBars(values: [.2, .5, .1, 1]),
                      Row(
                        children: [
                          Expanded(
                            child: SydexHeroTile(
                              label: 'Cash',
                              value: '₹12,34,56,789',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 120,
                  child: Row(
                    children: const [
                      Expanded(
                        child: SydexStatTile(
                          label: 'Outstanding',
                          value: '₹18,42,56,000',
                          icon: Icons.schedule_rounded,
                          footnote: 'Overdue ₹2,00,000',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SydexSection(
                  title: 'Quick actions',
                  actionLabel: 'See all',
                  onAction: () => tapped++,
                  child: GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: .78,
                    children: [
                      for (final label in const [
                        'Receive payment',
                        'Add sale',
                        'Old card import',
                        'View collections',
                      ])
                        SydexQuickAction(
                          icon: Icons.add,
                          label: label,
                          onTap: () => tapped++,
                        ),
                    ],
                  ),
                ),
                const SydexBadge('Refused', tone: SydexTone.negative),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Add sale'));
      await tester.tap(find.text('This week'));
      expect(tapped, 2);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('notifications screen renders empty state ($brightness)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      await tester.pumpWidget(
        _app(brightness, const OwnerNotificationsScreen()),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('No notifications yet.'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });
  }
}
