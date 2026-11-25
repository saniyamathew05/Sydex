import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

class SignatureService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  static String? errorMessage;

  /// Puts two signatures side by side in one picture, each with a caption, so
  /// a payment keeps both wherever its signature is shown.
  static Future<Uint8List> combine({
    required Uint8List customer,
    required Uint8List salesman,
  }) async {
    const boxWidth = 420.0;
    const boxHeight = 200.0;
    const gap = 40.0;
    const captionHeight = 44.0;
    const size = Size(boxWidth * 2 + gap, boxHeight + captionHeight);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    for (final (index, (bytes, caption)) in [
      (customer, 'Customer'),
      (salesman, 'Salesman'),
    ].indexed) {
      final left = index * (boxWidth + gap);
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      final scale = math.min(
        1.0,
        math.min(boxWidth / image.width, boxHeight / image.height),
      );
      final drawn = Size(image.width * scale, image.height * scale);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(
          left + (boxWidth - drawn.width) / 2,
          boxHeight - drawn.height,
          drawn.width,
          drawn.height,
        ),
        Paint()..filterQuality = FilterQuality.high,
      );
      image.dispose();
      codec.dispose();
      canvas.drawLine(
        Offset(left, boxHeight + 6),
        Offset(left + boxWidth, boxHeight + 6),
        Paint()
          ..color = const Color(0xFF9C978F)
          ..strokeWidth = 1.5,
      );
      final text = TextPainter(
        text: TextSpan(
          text: caption,
          style: const TextStyle(color: Color(0xFF55524C), fontSize: 24),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: boxWidth);
      text.paint(
        canvas,
        Offset(left + (boxWidth - text.width) / 2, boxHeight + 12),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw Exception('Could not combine the signatures.');
    return data.buffer.asUint8List();
  }

  // ------------------------------------------------------------
  // DOWNLOAD SIGNATURE
  // ------------------------------------------------------------

  static Future<Uint8List?> downloadSignature(String? signaturePath) async {
    errorMessage = null;

    if (signaturePath == null || signaturePath.isEmpty) {
      return null;
    }

    try {
      final bytes = await _supabase.storage
          .from('payment-signatures')
          .download(signaturePath);

      return bytes;
    } catch (error) {
      errorMessage = error.toString();
      return null;
    }
  }
}
