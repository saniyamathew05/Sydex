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
      data: {'name': ownerName, 'role': 'owner'},
    );
    if (response.user == null || response.session == null) return response;
    await _supabase.rpc('register_company', params: {'p_name': companyName});
    await _supabase.from('profiles').upsert({
      'id': response.user!.id,
      'name': ownerName,
      'role': 'owner',
    });
    return response;
  }
}
