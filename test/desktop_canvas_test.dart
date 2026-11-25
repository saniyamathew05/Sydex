import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sydex/services/signature_service.dart';
import 'package:sydex/widgets/desktop_canvas.dart';

void main() {
  double layoutWidth(double width, double ratio) =>
      width / DesktopCanvas.scaleFor(Size(width, 700), ratio);

  test('common Windows screens all get the same layout width', () {
    for (final (width, ratio) in const [
      (1536.0, 1.25), // 1920 x 1080 at 125%
      (1280.0, 1.5), // 1920 x 1080 at 150%
      (1366.0, 1.0), // 1366 x 768
      (1092.8, 1.25), // 1366 x 768 at 125%
      (910.7, 1.5), // 1366 x 768 at 150%
      (1280.0, 1.0), // 1280 x 720
    ]) {
      expect(
        layoutWidth(width, ratio),
        closeTo(DesktopCanvas.designWidth, .5),
        reason: '$width at $ratio',
      );
    }
    // A big screen is never enlarged, a narrow window keeps the phone layout.
    expect(DesktopCanvas.scaleFor(const Size(1920, 1080), 1), 1);
    expect(DesktopCanvas.scaleFor(const Size(600, 900), 1), 1);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('pages keep their state and stay clickable on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.reset);
      var pressed = 0;
      var width = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => DesktopCanvas(child: child!),
          home: Builder(
            builder: (context) {
              width = MediaQuery.sizeOf(context).width;
              return Scaffold(
                body: const TextField(),
                floatingActionButton: FloatingActionButton(
                  onPressed: () => pressed++,
                ),
              );
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Half-filled form');
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpAndSettle();
      expect(find.text('Half-filled form'), findsOneWidget);
      expect(width, platform == TargetPlatform.windows ? 1536 : 1280);
      await tester.tap(find.byType(FloatingActionButton));
      expect(pressed, 1);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('two signatures become one wide picture', (tester) async {
    await tester.runAsync(() async {
      Future<Uint8List> ink() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 300, 120),
          Paint()..color = const Color(0xFF000000),
        );
        final image = await recorder.endRecording().toImage(300, 120);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      }

      final png = await SignatureService.combine(
        customer: await ink(),
        salesman: await ink(),
      );
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      expect(image.width / image.height, greaterThan(3));
      final raw = (await image.toByteData())!;
      int red(int x, int y) => raw.getUint8((y * image.width + x) * 4);
      expect(red(210, 150), 0, reason: 'customer side is signed');
      expect(red(670, 150), 0, reason: 'salesman side is signed');
      expect(red(440, 150), 255, reason: 'the gap is blank');
    });
  });
}
