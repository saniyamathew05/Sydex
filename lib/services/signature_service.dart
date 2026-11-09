import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class SignatureService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  static String? errorMessage;

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
