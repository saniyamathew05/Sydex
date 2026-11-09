import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Preprocesses a handwritten card photo and requests a review-only AI draft.
/// No database rows are written by [extractCard].
class OldCardImportService {
  OldCardImportService._();

  static final SupabaseClient _supabase = Supabase.instance.client;

  static const int _maxImageBytes = 10 * 1024 * 1024;
  static const Set<String> _supportedMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };
  static const Set<String> _transactionTypes = {'sale', 'payment', 'return'};
  static const Set<String> _paymentMethods = {
    'unknown',
    'cash',
    'cheque',
    'neft',
    'gpay',
  };

  /// Extracts a draft from one selected customer's card photo.
  ///
  /// Preprocessing: decode, rotate sideways portrait photos to landscape,
  /// increase contrast, grayscale, upscale small images, and sharpen.
  /// The original photo is never modified on disk.
  static Future<Map<String, dynamic>> extractCard({
    required String customerId,
    required Uint8List imageBytes,
    required String mimeType,
  }) async {
    final id = customerId.trim();
    if (id.isEmpty) {
      throw ArgumentError('Select a customer before choosing a card image.');
    }
    if (imageBytes.isEmpty) {
      throw ArgumentError('The selected image is empty. Choose another image.');
    }
    if (imageBytes.length > _maxImageBytes) {
      throw ArgumentError(
        'The image is larger than 10 MB. Choose a smaller image.',
      );
    }

    final normalizedMimeType = mimeType.trim().toLowerCase();
    if (!_supportedMimeTypes.contains(normalizedMimeType)) {
      throw ArgumentError(
        'Unsupported image type. Choose a JPG, PNG, or WebP image.',
      );
    }

    final prepared = _preprocessImage(imageBytes);
    final response = await _supabase.functions.invoke(
      'extract-old-card',
      body: <String, dynamic>{
        'customerId': id,
        'mimeType': 'image/jpeg',
        'imageBase64': base64Encode(prepared),
      },
    );

    _throwForHttpError(response.status, response.data);
    final result = _asMap(response.data, 'card extraction');
    if (result['saved'] != false ||
        result['requiresOwnerReview'] != true ||
        result['entries'] is! List) {
      final message = _readError(result);
      throw FormatException(
        message.isEmpty
            ? 'The service did not return a review-only draft.'
            : message,
      );
    }
    return result;
  }

  static Uint8List _preprocessImage(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw ArgumentError(
        'Could not open this image. Try saving it as a JPG and uploading again.',
      );
    }

    var processed = img.bakeOrientation(decoded);

    // The sample card is a landscape card photographed sideways, creating a
    // tall portrait image. Rotate it so the three columns read left-to-right.
    if (processed.height > processed.width * 1.15) {
      processed = img.copyRotate(processed, angle: 90);
    }

    // Keep enough resolution for handwritten digits while limiting payload.
    const maxSide = 2200;
    final longestSide = processed.width > processed.height
        ? processed.width
        : processed.height;
    if (longestSide < 1500) {
      final scale = 1500 / longestSide;
      processed = img.copyResize(
        processed,
        width: (processed.width * scale).round(),
        height: (processed.height * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    } else if (longestSide > maxSide) {
      final scale = maxSide / longestSide;
      processed = img.copyResize(
        processed,
        width: (processed.width * scale).round(),
        height: (processed.height * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    }

    processed = img.grayscale(processed);
    processed = img.adjustColor(processed, contrast: 1.28, brightness: 1.03);
    processed = img.convolution(
      processed,
      filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
      div: 1,
      offset: 0,
    );

    return Uint8List.fromList(img.encodeJpg(processed, quality: 94));
  }

  /// Call only after displaying an explicit confirmation to the owner.
  /// The server checks owner permissions, balances, dates, and customer state.
  static Future<Map<String, dynamic>> importReviewedEntries({
    required String customerId,
    required List<Map<String, dynamic>> entries,
  }) async {
    final id = customerId.trim();
    if (id.isEmpty) throw ArgumentError('Select a customer first.');
    if (entries.isEmpty) {
      throw ArgumentError('There are no reviewed entries to import.');
    }
    if (entries.length > 500) {
      throw ArgumentError('Import no more than 500 entries at a time.');
    }

    final cleanedEntries = <Map<String, dynamic>>[];
    DateTime? previousDate;

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final index = i + 1;
      final dateText = (entry['date'] ?? '').toString().trim();
      final parsedDate = DateTime.tryParse(dateText);
      if (parsedDate == null ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText)) {
        throw ArgumentError(
          'Entry $index needs a valid date in YYYY-MM-DD format.',
        );
      }
      if (previousDate != null && parsedDate.isBefore(previousDate)) {
        throw ArgumentError(
          'Put entries in date order, from oldest to newest.',
        );
      }
      previousDate = parsedDate;

      final type = (entry['type'] ?? '').toString().trim();
      if (!_transactionTypes.contains(type)) {
        throw ArgumentError(
          'Choose New Sale, Payment Received, or Sales Return for entry $index.',
        );
      }

      final amount = double.tryParse((entry['amount'] ?? '').toString().trim());
      if (amount == null || !amount.isFinite || amount <= 0) {
        throw ArgumentError(
          'Entry $index must have an amount greater than zero.',
        );
      }

      final method = (entry['paymentMethod'] ?? 'unknown').toString().trim();
      if (!_paymentMethods.contains(method)) {
        throw ArgumentError('Choose a valid payment method for entry $index.');
      }

      final balanceText = (entry['writtenBalanceAfter'] ?? '')
          .toString()
          .trim();
      double? writtenBalance;
      if (balanceText.isNotEmpty) {
        writtenBalance = double.tryParse(balanceText);
        if (writtenBalance == null ||
            !writtenBalance.isFinite ||
            writtenBalance < 0) {
          throw ArgumentError('Entry $index has an invalid written balance.');
        }
      }
      if (i == 0 && writtenBalance == null) {
        throw ArgumentError(
          'The first entry needs its written balance after the transaction '
          'so the starting balance can be validated.',
        );
      }

      cleanedEntries.add(<String, dynamic>{
        'date': dateText,
        'type': type,
        'amount': amount.toStringAsFixed(2),
        'writtenBalanceAfter': writtenBalance?.toStringAsFixed(2) ?? '',
        'paymentMethod': method,
        'notes': (entry['notes'] ?? '').toString().trim(),
        'rawText': (entry['rawText'] ?? '').toString(),
      });
    }

    final response = await _supabase.rpc(
      'import_old_card_transactions',
      params: <String, dynamic>{
        'p_customer_id': id,
        'p_entries': cleanedEntries,
      },
    );

    final result = _asMap(response, 'historical import');
    if (result['success'] != true) {
      final message = _readError(result);
      throw FormatException(
        message.isEmpty
            ? 'The historical import was not confirmed by the server.'
            : message,
      );
    }
    return result;
  }

  static void _throwForHttpError(int status, dynamic data) {
    if (status < 200 || status >= 300) {
      final message = _readError(data);
      throw Exception(
        message.isEmpty
            ? 'Could not extract the card (HTTP $status).'
            : message,
      );
    }
  }

  static Map<String, dynamic> _asMap(dynamic value, String operation) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw FormatException(
      'The $operation service returned an unexpected response.',
    );
  }

  static String _readError(dynamic data) {
    if (data is Map) {
      final message = data['error'] ?? data['message'];
      if (message != null) return message.toString();
    }
    if (data is String) return data;
    return '';
  }
}
