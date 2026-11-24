import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sydex/services/profile_store.dart';

Future<Uint8List> _picture({Color? background}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (background != null) {
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 60, 30),
      Paint()..color = background,
    );
  }
  final image = await recorder.endRecording().toImage(60, 30);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<(int, int, Color)> _centre(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final raw = (await image.toByteData())!;
  final at = (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
  return (
    image.width,
    image.height,
    Color.fromARGB(
      raw.getUint8(at + 3),
      raw.getUint8(at),
      raw.getUint8(at + 1),
      raw.getUint8(at + 2),
    ),
  );
}

void main() {
  testWidgets('a chosen photo keeps its colours and is never black', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await ProfileStore.setPhoto(
        await _picture(background: const Color(0xFFCC3311)),
      );
      expect(
        await _centre(ProfileStore.photo.value!),
        (256, 256, const Color(0xFFCC3311)),
      );

      // See-through pictures get a white background.
      await ProfileStore.setPhoto(await _picture());
      expect(
        (await _centre(ProfileStore.photo.value!)).$3,
        const Color(0xFFFFFFFF),
      );

      await expectLater(
        ProfileStore.setPhoto(Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );
      await ProfileStore.removePhoto();
      expect(ProfileStore.photo.value, isNull);
    });
  });
}
