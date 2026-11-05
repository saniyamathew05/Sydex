import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/transaction.dart';

class PaymentReceiptService {
  PaymentReceiptService._();

  static final SupabaseClient _supabase = Supabase.instance.client;

  static Future<void> sendWhatsAppReceipt({
    required String customerId,
    required PaymentTransaction payment,
  }) async {
    final image = await _buildReceiptImage(payment);
    final response = await _supabase.functions.invoke(
      'send-whatsapp-payment-receipt',
      body: {
        'customerId': customerId,
        'paymentId': payment.id,
        'customerConsented': true,
        'receiptImageBase64': base64Encode(image),
      },
    );

    final data = response.data;
    if (response.status < 200 || response.status >= 300) {
      final message = data is Map ? data['error']?.toString() : null;
      throw Exception(
        message ?? 'WhatsApp returned status ${response.status}.',
      );
    }
    if (data is Map && data['sent'] != true) {
      throw Exception(
        data['error']?.toString() ?? 'WhatsApp did not confirm delivery.',
      );
    }
  }

  /// Creates a receipt image for preview and manual sharing from the device.
  static Future<Uint8List> buildReceiptImage(
    PaymentTransaction payment, {
    Uint8List? signatureBytes,
  }) => _buildReceiptImage(payment, signatureBytes: signatureBytes);

  static Future<Uint8List> _buildReceiptImage(
    PaymentTransaction payment, {
    Uint8List? signatureBytes,
  }) async {
    const width = 840;
    const height = 1260;
    const green = Color(0xFF0B5D3B);
    const ink = Color(0xFF14211A);
    const muted = Color(0xFF657066);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    canvas.drawColor(const Color(0xFFF7F3EC), BlendMode.src);
    final card = RRect.fromRectAndRadius(
      const Rect.fromLTWH(36, 36, 768, 1188),
      const Radius.circular(28),
    );
    canvas.drawRRect(card, Paint()..color = Colors.white);
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(
        36,
        36,
        804,
        270,
        topLeft: Radius.circular(28),
        topRight: Radius.circular(28),
      ),
      Paint()..color = green,
    );

    _drawText(
      canvas,
      'ABS controls',
      76,
      78,
      680,
      color: Colors.white,
      size: 22,
      weight: FontWeight.w700,
      spacing: 1.5,
    );
    _drawText(
      canvas,
      'Payment received',
      76,
      126,
      680,
      color: Colors.white,
      size: 42,
      weight: FontWeight.w800,
    );
    _drawText(
      canvas,
      'RECEIPT',
      76,
      195,
      680,
      color: const Color(0xFFDDF3E5),
      size: 20,
      weight: FontWeight.w700,
    );

    var y = 316.0;
    _drawText(
      canvas,
      payment.customerName,
      76,
      y,
      680,
      color: ink,
      size: 30,
      weight: FontWeight.w800,
      maxLines: 2,
    );
    y += 84;

    final date = payment.transactionDate.toLocal();
    final dateLabel =
        '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}  '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
    _drawText(
      canvas,
      'DATE',
      76,
      y,
      280,
      color: muted,
      size: 16,
      weight: FontWeight.w600,
    );
    _drawText(
      canvas,
      dateLabel,
      400,
      y,
      360,
      color: ink,
      size: 19,
      weight: FontWeight.w600,
      alignRight: true,
    );
    y += 48;
    _drawRule(canvas, y);
    y += 34;

    _drawRow(
      canvas,
      'Settlement amount',
      _money(payment.amount),
      y,
      labelColor: muted,
      valueColor: ink,
    );
    y += 56;
    if (payment.discount > 0) {
      _drawRow(
        canvas,
        'Discount',
        _money(payment.discount),
        y,
        labelColor: muted,
        valueColor: ink,
      );
      y += 56;
    }

    final received = payment.amountReceived > 0
        ? payment.amountReceived
        : payment.amount - payment.discount;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(64, y, 712, 100),
        const Radius.circular(18),
      ),
      Paint()..color = const Color(0xFFEAF3EC),
    );
    _drawText(
      canvas,
      'AMOUNT RECEIVED',
      88,
      y + 18,
      360,
      color: green,
      size: 16,
      weight: FontWeight.w700,
    );
    _drawText(
      canvas,
      _money(received),
      440,
      y + 14,
      300,
      color: green,
      size: 33,
      weight: FontWeight.w800,
      alignRight: true,
    );
    y += 132;

    _drawRow(
      canvas,
      'Payment method',
      _methodName(payment.paymentMethod),
      y,
      labelColor: muted,
      valueColor: ink,
    );
    y += 56;
    _drawRow(
      canvas,
      'Previous balance',
      _money(payment.previousBalance),
      y,
      labelColor: muted,
      valueColor: ink,
    );
    y += 56;
    _drawRow(
      canvas,
      'Balance after payment',
      _money(payment.remainingBalance),
      y,
      labelColor: muted,
      valueColor: ink,
    );
    y += 56;

    final methodNote = payment.paymentMethodNote.trim();
    if (methodNote.isNotEmpty && y < 890) {
      _drawText(
        canvas,
        'PAYMENT NOTE',
        76,
        y,
        680,
        color: muted,
        size: 14,
        weight: FontWeight.w700,
      );
      y += 26;
      _drawText(
        canvas,
        methodNote,
        76,
        y,
        680,
        color: ink,
        size: 17,
        maxLines: 2,
      );
      y += 52;
    }
    final notes = payment.notes.trim();
    if (notes.isNotEmpty && y < 890) {
      _drawText(
        canvas,
        'NOTES',
        76,
        y,
        680,
        color: muted,
        size: 14,
        weight: FontWeight.w700,
      );
      y += 26;
      _drawText(canvas, notes, 76, y, 680, color: ink, size: 17, maxLines: 3);
      y += 60;
    }

    if (signatureBytes != null && signatureBytes.isNotEmpty) {
      _drawText(
        canvas,
        'CUSTOMER SIGNATURE',
        76,
        990,
        680,
        color: muted,
        size: 14,
        weight: FontWeight.w700,
      );
      final codec = await ui.instantiateImageCodec(signatureBytes);
      final frame = await codec.getNextFrame();
      final signatureImage = frame.image;
      final source = Rect.fromLTWH(
        0,
        0,
        signatureImage.width.toDouble(),
        signatureImage.height.toDouble(),
      );
      final destination = _containRect(
        source.width,
        source.height,
        const Rect.fromLTWH(76, 1020, 400, 110),
      );
      canvas.drawImageRect(signatureImage, source, destination, Paint());
      signatureImage.dispose();
      codec.dispose();
    }

    _drawRule(canvas, 1162);
    _drawText(
      canvas,
      'Thank you for your payment.',
      76,
      1184,
      680,
      color: muted,
      size: 17,
      weight: FontWeight.w600,
      alignRight: true,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (byteData == null) {
      throw Exception('Could not create the receipt image.');
    }
    return byteData.buffer.asUint8List();
  }

  static void _drawRow(
    Canvas canvas,
    String label,
    String value,
    double y, {
    required Color labelColor,
    required Color valueColor,
  }) {
    _drawText(
      canvas,
      label,
      76,
      y,
      340,
      color: labelColor,
      size: 19,
      weight: FontWeight.w500,
    );
    _drawText(
      canvas,
      value,
      416,
      y,
      348,
      color: valueColor,
      size: 19,
      weight: FontWeight.w700,
      alignRight: true,
    );
  }

  static void _drawRule(Canvas canvas, double y) {
    canvas.drawLine(
      Offset(76, y),
      Offset(764, y),
      Paint()
        ..color = const Color(0xFFE4DED4)
        ..strokeWidth = 2,
    );
  }

  static Rect _containRect(
    double sourceWidth,
    double sourceHeight,
    Rect bounds,
  ) {
    final widthScale = bounds.width / sourceWidth;
    final heightScale = bounds.height / sourceHeight;
    final scale = widthScale < heightScale ? widthScale : heightScale;
    final width = sourceWidth * scale;
    final height = sourceHeight * scale;
    return Rect.fromLTWH(
      bounds.left + (bounds.width - width) / 2,
      bounds.top + (bounds.height - height) / 2,
      width,
      height,
    );
  }

  static void _drawText(
    Canvas canvas,
    String text,
    double x,
    double y,
    double maxWidth, {
    required Color color,
    required double size,
    FontWeight weight = FontWeight.w400,
    bool alignRight = false,
    int maxLines = 1,
    double spacing = 0,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          letterSpacing: spacing,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(
      canvas,
      Offset(alignRight ? x + maxWidth - painter.width : x, y),
    );
  }

  static String _money(double amount) => '₹${amount.toStringAsFixed(2)}';

  static String _methodName(String method) {
    if (method.trim().isEmpty) return 'Not specified';
    return method
        .replaceAll('_', ' ')
        .split(' ')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }
}
