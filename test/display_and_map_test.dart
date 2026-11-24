import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sydex/services/owner_display_settings.dart';
import 'package:sydex/theme/sydex_theme.dart';
import 'package:sydex/theme/workspace_theme.dart';
import 'package:sydex/widgets/customer_map.dart';
import 'package:sydex/widgets/sydex_ui.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: workspaceTheme(buildSydexTheme(brightness, SydexColors.ink)),
      home: Scaffold(body: child),
    );

void main() {
  test('owner choices are kept, including ones from earlier versions', () async {
    SharedPreferences.setMockInitialValues({
      'sydex_owner_show_recent_payments': false,
    });
    await OwnerDisplaySettings.load();
    expect(
      OwnerDisplaySettings.show(OwnerDisplaySettings.recentPayments),
      isFalse,
    );
    expect(OwnerDisplaySettings.show(OwnerDisplaySettings.notes), isTrue);

    await OwnerDisplaySettings.set(OwnerDisplaySettings.notes, false);
    await OwnerDisplaySettings.load();
    expect(OwnerDisplaySettings.show(OwnerDisplaySettings.notes), isFalse);

    await OwnerDisplaySettings.reset();
    expect(
      OwnerDisplaySettings.show(OwnerDisplaySettings.recentPayments),
      isTrue,
    );
  });

  for (final size in const [Size(390, 700), Size(1200, 800), Size(800, 180)]) {
    testWidgets('map names every customer and leads to the next stop $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          const CustomerMap(
            currentLocation: LatLng(8.50, 76.90),
            stops: [
              CustomerStop(
                id: 'a',
                name: 'Visited Stores',
                place: 'Town',
                point: LatLng(8.505, 76.901),
                order: 1,
                status: 'paid',
              ),
              CustomerStop(
                id: 'b',
                name: 'Next Traders',
                place: 'Town',
                point: LatLng(8.51, 76.905),
                order: 2,
              ),
              CustomerStop(
                id: 'c',
                name: 'Other Mart',
                place: 'Town',
                point: LatLng(8.507, 76.903),
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('Next stop'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
      // Once above its pin and once in the card.
      expect(find.text('Next Traders'), findsNWidgets(2));
      if (size.height > 300) {
        expect(find.text('Visited Stores'), findsOneWidget);
        expect(find.text('Other Mart'), findsOneWidget);
        await tester.tap(find.text('Other Mart'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Other Mart'), findsNWidgets(2));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('a filter drop-down shows its choice and changes it', (
    tester,
  ) async {
    var chosen = 'Today';
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => SydexFilterDropdown(
            label: 'Date',
            options: const ['Today', 'This week'],
            selected: chosen,
            onSelected: (value) => setState(() => chosen = value),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This week'));
    await tester.pumpAndSettle();
    expect(chosen, 'This week');
    expect(find.text('This week'), findsOneWidget);
  });
}
