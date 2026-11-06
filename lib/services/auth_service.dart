import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthService {
  static const _oauthAttemptKey = 'horizon_google_oauth_attempt_at';
  static const _nativeOAuthRedirectUri = 'io.horizon.app://login-callback';
  static const _oauthAttemptLifetime = Duration(minutes: 10);

  static final SupabaseClient _supabase = Supabase.instance.client;

  static User? get currentUser => _supabase.auth.currentUser;

  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    await clearPendingGoogleSignIn();
    final response = await _supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );

    if (response.user != null) {
      await clearOwnForceLogout();
      await clearPendingGoogleSignIn();
    }

    return response;
  }

  /// Opens Google's secure OAuth flow. The returned session is received by the
  /// existing Supabase auth callback and observed by the login screen.
  static Future<bool> signInWithGoogle() async {
    await _markPendingGoogleSignIn();
    try {
      return await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: _oauthRedirectUri,
      );
    } catch (_) {
      await clearPendingGoogleSignIn();
      rethrow;
    }
  }

  /// Keeps automatic logout intact while allowing an OAuth browser callback to
  /// finish after the app is reopened.
  static Future<bool> hasPendingGoogleSignIn() async {
    final preferences = await SharedPreferences.getInstance();
    final rawTimestamp = preferences.getInt(_oauthAttemptKey);
    if (rawTimestamp == null) return false;

    final startedAt = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
    if (DateTime.now().difference(startedAt) <= _oauthAttemptLifetime) {
      return true;
    }
    await preferences.remove(_oauthAttemptKey);
    return false;
  }

  static Future<void> clearPendingGoogleSignIn() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_oauthAttemptKey);
  }

  static Future<void> _markPendingGoogleSignIn() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _oauthAttemptKey,
      DateTime.now().millisecondsSinceEpoch,
    );
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
    await clearPendingGoogleSignIn();
    await _supabase.auth.signOut();
  }

  static Future<void> requestPasswordReset(String email) {
    return _supabase.auth.resetPasswordForEmail(
      email,
      redirectTo: _webRedirectUri,
    );
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
      data: {'name': ownerName, 'role': 'owner', 'company_name': companyName},
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

  static String? get _oauthRedirectUri =>
      kIsWeb ? _webRedirectUri : _nativeOAuthRedirectUri;

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
    if (companyName == null ||
        companyName.isEmpty ||
        ownerName == null ||
        ownerName.isEmpty) {
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
