import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  static User? get currentUser => _supabase.auth.currentUser;

  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );

    if (response.user != null) {
      await clearOwnForceLogout();
    }

    return response;
  }

  static Future<Map<String, dynamic>?> getProfile(String userId) async {
    return _supabase
        .from('profiles')
        .select('name, role')
        .eq('id', userId)
        .maybeSingle();
  }

  static Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    final user = currentUser;

    if (user == null) {
      return null;
    }

    return getProfile(user.id);
  }

  static Future<void> clearOwnForceLogout() async {
    await _supabase.rpc('clear_own_force_logout');
  }

  static Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  static Future<AuthResponse> registerCompany({
    required String companyName,
    required String ownerName,
    required String email,
    required String password,
  }) async {
    final response = await _supabase.auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: _webRedirectUri,
      data: {
        'name': ownerName,
        'role': 'owner',
        'company_name': companyName,
      },
    );
    if (response.user == null || response.session == null) return response;
    await completeCompanyRegistration(response.user!);
    return response;
  }

  static String? get _webRedirectUri {
    if (!kIsWeb) return null;
    final origin = Uri.base.origin;
    return origin.startsWith('http') ? origin : null;
  }

  /// Creates the company/profile after email confirmation when Supabase does
  /// not issue a session during sign-up. Safe to call repeatedly after login.
  static Future<void> completeCompanyRegistration(User user) async {
    final profile = await _supabase
        .from('profiles')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();
    if (profile != null) return;

    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final companyName = metadata['company_name']?.toString().trim();
    final ownerName = metadata['name']?.toString().trim();
    if (companyName == null || companyName.isEmpty ||
        ownerName == null || ownerName.isEmpty) {
      return;
    }

    await _supabase.rpc('register_company', params: {'p_name': companyName});
    await _supabase.from('profiles').upsert({
      'id': user.id,
      'name': ownerName,
      'role': 'owner',
    });
  }
}
