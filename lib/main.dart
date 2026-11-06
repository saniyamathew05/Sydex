import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/owner/owner_main_screen.dart';

import 'screens/salesman/salesman_home.dart';

import 'services/theme_controller.dart';

import 'services/auth_service.dart';
import 'services/business_date_service.dart';
import 'theme/ledgerpro_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = 'https://rxjexwtdhopkltrrlbnd.supabase.co';

  const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  if (supabasePublishableKey.isEmpty) {
    throw Exception('SUPABASE_PUBLISHABLE_KEY was not provided.');
  }

  await Supabase.initialize(
    url: supabaseUrl,

    publishableKey: supabasePublishableKey,
  );

  // Sessions are intentionally not restored across app launches. This keeps
  // a closed/shared device from reopening the last business account, even if
  // the operating system terminated the process before lifecycle cleanup ran.
  // Preserve a web confirmation callback long enough for AuthGate to exchange
  // its one-time code for a session. Other launches still start signed out.
  final hasConfirmationCode =
      kIsWeb && Uri.base.queryParameters['code']?.trim().isNotEmpty == true;
  if (!hasConfirmationCode) {
    try {
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    } catch (error) {
      debugPrint('Could not clear the previous local session: $error');
    }
  }

  await ThemeController.loadTheme();
  await BusinessDateService.load();

  runApp(const BusinessPaymentApp());
}

// ============================================================

// APP

// ============================================================

class BusinessPaymentApp extends StatefulWidget {
  const BusinessPaymentApp({super.key});

  @override
  State<BusinessPaymentApp> createState() => _BusinessPaymentAppState();
}

class _BusinessPaymentAppState extends State<BusinessPaymentApp>
    with WidgetsBindingObserver {
  Future<void>? _closeSignOut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_signOutOnClose());
    }
  }

  Future<void> _signOutOnClose() => _closeSignOut ??= _performSignOutOnClose();

  Future<void> _performSignOutOnClose() async {
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession == null) return;
    try {
      await auth.signOut(scope: SignOutScope.local);
    } catch (error) {
      // The launch-time logout below also covers forced closes and shutdowns
      // where Flutter cannot finish this asynchronous cleanup.
      debugPrint('Could not complete sign-out while closing the app: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.themeMode,
      builder: (context, themeMode, _) => ValueListenableBuilder<Color>(
        valueListenable: ThemeController.accentColor,
        builder: (context, accent, _) => MaterialApp(
          debugShowCheckedModeBanner: false,

          title: 'LedgerPro',

          themeMode: themeMode,

          theme: _buildLightTheme(accent),

          darkTheme: _buildDarkTheme(accent),

          home: const AuthGate(),
        ),
      ),
    );
  }

  // ==========================================================

  // LIGHT THEME

  // ==========================================================

  ThemeData _buildLightTheme(Color primary) {
    final secondary = primary.withValues(alpha: .88);
    final primaryContainer = Color.alphaBlend(
      primary.withValues(alpha: .14),
      Colors.white,
    );
    final onPrimaryContainer = Color.lerp(primary, Colors.black, .32)!;

    const background = LedgerProTokens.background;

    const surface = Color(0xFFFFFFFF);

    const border = LedgerProTokens.border;

    const textPrimary = LedgerProTokens.text;

    const textSecondary = LedgerProTokens.muted;

    final colorScheme = ColorScheme.light(
      primary: primary,

      onPrimary: Colors.white,

      primaryContainer: primaryContainer,

      onPrimaryContainer: onPrimaryContainer,

      secondary: secondary,

      onSecondary: Colors.white,

      secondaryContainer: primaryContainer,

      onSecondaryContainer: onPrimaryContainer,

      surface: surface,

      onSurface: textPrimary,

      surfaceContainerLowest: Colors.white,

      surfaceContainerLow: const Color(0xFFFAFCFA),

      surfaceContainer: const Color(0xFFF3F7F4),

      surfaceContainerHigh: const Color(0xFFEAF3EC),

      surfaceContainerHighest: const Color(0xFFE2EDE4),

      onSurfaceVariant: textSecondary,

      outline: const Color(0xFFBFCFC2),

      outlineVariant: border,

      error: const Color(0xFFDC2626),

      onError: Colors.white,

      errorContainer: const Color(0xFFFEE2E2),

      onErrorContainer: const Color(0xFF7F1D1D),
    );

    return ThemeData(
      useMaterial3: true,

      brightness: Brightness.light,

      colorScheme: colorScheme,

      textTheme: LedgerProTokens.textTheme(
        ThemeData.light().textTheme,
      ).apply(bodyColor: textPrimary, displayColor: textPrimary),

      primaryTextTheme: ThemeData.light().primaryTextTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),

      iconTheme: const IconThemeData(color: textSecondary),

      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textSecondary,
      ),

      popupMenuTheme: const PopupMenuThemeData(
        color: surface,
        textStyle: TextStyle(color: textPrimary),
      ),

      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: Color(0xFF071B12),
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        textStyle: TextStyle(color: Colors.white),
      ),

      dataTableTheme: const DataTableThemeData(
        headingTextStyle: TextStyle(
          color: textPrimary,
          fontWeight: FontWeight.w700,
        ),
        dataTextStyle: TextStyle(color: textPrimary),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFFF3F7F4),
        labelStyle: const TextStyle(color: textPrimary),
        secondaryLabelStyle: const TextStyle(color: textPrimary),
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      scaffoldBackgroundColor: background,

      appBarTheme: const AppBarTheme(
        backgroundColor: surface,

        foregroundColor: textPrimary,

        elevation: 0,

        centerTitle: false,

        surfaceTintColor: Colors.transparent,
      ),

      cardTheme: CardThemeData(
        color: surface,

        elevation: 0,

        margin: EdgeInsets.zero,

        surfaceTintColor: Colors.transparent,

        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusCard),

          side: const BorderSide(color: border),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,

        fillColor: const Color(0xFFF4F7F3),

        floatingLabelBehavior: FloatingLabelBehavior.auto,

        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,

          vertical: 15,
        ),

        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: border),
        ),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: border),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: BorderSide(color: primary, width: 2),
        ),

        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: Color(0xFFDC2626)),
        ),

        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: Color(0xFFDC2626), width: 2),
        ),

        labelStyle: const TextStyle(color: textSecondary),

        hintStyle: const TextStyle(color: Color(0xFF94A3A0)),

        prefixIconColor: textSecondary,

        suffixIconColor: textSecondary,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,

          foregroundColor: Colors.white,

          disabledBackgroundColor: const Color(0xFFCBD5D1),

          disabledForegroundColor: const Color(0xFF657066),

          elevation: 0,

          minimumSize: const Size(0, 50),

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),
          ),

          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,

          minimumSize: const Size(0, 50),

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

          side: const BorderSide(color: border),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),
          ),

          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),

          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,

        foregroundColor: Colors.white,

        elevation: 3,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,

        indicatorColor: primaryContainer,

        elevation: 0,

        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,

              fontWeight: FontWeight.w700,

              color: primary,
            );
          }

          return TextStyle(
            fontSize: 12,

            fontWeight: FontWeight.w500,

            color: textSecondary,
          );
        }),

        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: primary);
          }

          return const IconThemeData(color: textSecondary);
        }),
      ),

      dividerTheme: const DividerThemeData(
        color: border,

        thickness: 1,

        space: 1,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,

        backgroundColor: const Color(0xFF071B12),

        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: surface,

        surfaceTintColor: Colors.transparent,

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,

        surfaceTintColor: Colors.transparent,

        showDragHandle: true,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
    );
  }

  // ==========================================================

  // DARK THEME

  // ==========================================================

  ThemeData _buildDarkTheme(Color accent) {
    final primary = Color.lerp(accent, Colors.white, .42)!;

    final secondary = Color.lerp(accent, Colors.white, .25)!;

    const background = LedgerProTokens.navy;

    const surface = LedgerProTokens.navySoft;

    final primaryContainer = Color.alphaBlend(
      accent.withValues(alpha: .34),
      surface,
    );

    const border = Color(0xFF345245);

    const textPrimary = Color(0xFFF3F7F4);

    const textSecondary = Color(0xFFC0D0C4);

    final colorScheme = ColorScheme.dark(
      primary: primary,

      onPrimary: const Color(0xFF063D28),

      primaryContainer: primaryContainer,

      onPrimaryContainer: const Color(0xFFDDF3E5),

      secondary: secondary,

      onSecondary: const Color(0xFF063D28),

      secondaryContainer: primaryContainer,

      onSecondaryContainer: const Color(0xFFDDF3E5),

      surface: surface,

      onSurface: textPrimary,

      surfaceContainerLowest: const Color(0xFF071B12),

      surfaceContainerLow: const Color(0xFF0D2A1D),

      surfaceContainer: const Color(0xFF102B20),

      surfaceContainerHigh: const Color(0xFF173729),

      surfaceContainerHighest: const Color(0xFF1C4431),

      onSurfaceVariant: textSecondary,

      outline: const Color(0xFF73917E),

      outlineVariant: border,

      error: const Color(0xFFF87171),

      onError: const Color(0xFF450A0A),

      errorContainer: const Color(0xFF4C1D1D),

      onErrorContainer: const Color(0xFFFECACA),
    );

    return ThemeData(
      useMaterial3: true,

      brightness: Brightness.dark,

      colorScheme: colorScheme,

      textTheme: LedgerProTokens.textTheme(
        ThemeData.dark().textTheme,
      ).apply(bodyColor: textPrimary, displayColor: textPrimary),

      primaryTextTheme: ThemeData.dark().primaryTextTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),

      iconTheme: const IconThemeData(color: textSecondary),

      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textSecondary,
      ),

      popupMenuTheme: const PopupMenuThemeData(
        color: surface,
        textStyle: TextStyle(color: textPrimary),
      ),

      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: Color(0xFF1C4431),
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        textStyle: TextStyle(color: textPrimary),
      ),

      dataTableTheme: const DataTableThemeData(
        headingTextStyle: TextStyle(
          color: textPrimary,
          fontWeight: FontWeight.w700,
        ),
        dataTextStyle: TextStyle(color: textPrimary),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF173729),
        labelStyle: const TextStyle(color: textPrimary),
        secondaryLabelStyle: const TextStyle(color: textPrimary),
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      scaffoldBackgroundColor: background,

      appBarTheme: const AppBarTheme(
        backgroundColor: background,

        foregroundColor: textPrimary,

        elevation: 0,

        centerTitle: false,

        surfaceTintColor: Colors.transparent,
      ),

      cardTheme: CardThemeData(
        color: surface,

        elevation: 0,

        margin: EdgeInsets.zero,

        surfaceTintColor: Colors.transparent,

        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusCard),

          side: const BorderSide(color: border),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,

        fillColor: const Color(0xFF102B20),

        floatingLabelBehavior: FloatingLabelBehavior.auto,

        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,

          vertical: 15,
        ),

        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: border),
        ),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: border),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: BorderSide(color: primary, width: 2),
        ),

        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: Color(0xFFF87171)),
        ),

        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),

          borderSide: const BorderSide(color: Color(0xFFF87171), width: 2),
        ),

        labelStyle: const TextStyle(color: textSecondary),

        hintStyle: const TextStyle(color: Color(0xFFC0D0C4)),

        prefixIconColor: textSecondary,

        suffixIconColor: textSecondary,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,

          foregroundColor: const Color(0xFF063D28),

          disabledBackgroundColor: const Color(0xFF345245),

          disabledForegroundColor: const Color(0xFFE0ECE2),

          elevation: 0,

          minimumSize: const Size(0, 50),

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LedgerProTokens.radiusSmall),
          ),

          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,

          minimumSize: const Size(0, 50),

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

          side: const BorderSide(color: border),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),

          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),

          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,

        foregroundColor: Color(0xFF063D28),

        elevation: 3,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,

        indicatorColor: primaryContainer,

        elevation: 0,

        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,

              fontWeight: FontWeight.w700,

              color: primary,
            );
          }

          return TextStyle(
            fontSize: 12,

            fontWeight: FontWeight.w500,

            color: textSecondary,
          );
        }),

        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: primary);
          }

          return const IconThemeData(color: textSecondary);
        }),
      ),

      dividerTheme: const DividerThemeData(
        color: border,

        thickness: 1,

        space: 1,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,

        backgroundColor: const Color(0xFF1C4431),

        contentTextStyle: const TextStyle(
          color: Color(0xFFF3F7F4),

          fontSize: 13,
        ),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: surface,

        surfaceTintColor: Colors.transparent,

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,

        surfaceTintColor: Colors.transparent,

        showDragHandle: true,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
    );
  }
}

// ============================================================

// AUTH GATE

// ============================================================

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool isLoading = true;

  String? errorMessage;

  bool _handledCallback = false;

  @override
  void initState() {
    super.initState();

    _checkCurrentUser();
  }

  Future<void> _checkCurrentUser() async {
    User? user = AuthService.currentUser;

    if (kIsWeb && !_handledCallback) {
      _handledCallback = true;
      final code = Uri.base.queryParameters['code'];
      if (code != null && code.isNotEmpty) {
        try {
          final response = await Supabase.instance.client.auth
              .exchangeCodeForSession(code);
          user = response.session?.user ?? AuthService.currentUser;
        } catch (error) {
          if (!mounted) return;
          setState(() {
            errorMessage =
                'Email confirmation could not be completed. Please request a new link.';
            isLoading = false;
          });
          return;
        }
      }
    }

    if (user == null) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      return;
    }

    await _openCorrectDashboard(user.id);
  }

  Future<void> _openCorrectDashboard(String userId) async {
    try {
      final user = AuthService.currentUser;
      if (user != null) {
        await AuthService.completeCompanyRegistration(user);
      }
      final profile = await AuthService.getProfile(userId);

      if (profile == null) {
        await AuthService.signOut();

        if (!mounted) return;

        setState(() {
          errorMessage = 'Your account profile was not found.';

          isLoading = false;
        });

        return;
      }

      final role = profile['role'] as String;

      final name = profile['name'] as String;

      if (!mounted) return;

      if (role == 'owner') {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const OwnerMainScreen()),
        );
      } else if (role == 'salesman') {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => SalesmanHome(userName: name)),
        );
      } else {
        await AuthService.signOut();

        setState(() {
          errorMessage = 'Invalid account role.';

          isLoading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        errorMessage = error.toString();

        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return LoginScreen(initialError: errorMessage);
  }
}

// ============================================================

// LOGIN SCREEN

// ============================================================

class LoginScreen extends StatefulWidget {
  final String? initialError;

  const LoginScreen({super.key, this.initialError});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();

  final passwordController = TextEditingController();

  bool isLoading = false;

  bool obscurePassword = true;

  @override
  void initState() {
    super.initState();

    if (widget.initialError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showError(widget.initialError!);
        }
      });
    }
  }

  @override
  void dispose() {
    emailController.dispose();

    passwordController.dispose();

    super.dispose();
  }

  Future<void> login() async {
    final email = emailController.text.trim();

    final password = passwordController.text;

    if (email.isEmpty ||
        password.isEmpty ||
        email.length > 254 ||
        password.length > 128) {
      _showError('Please enter a valid email and password.');

      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final response = await AuthService.signIn(
        email: email,

        password: password,
      );

      final user = response.user;

      if (user == null) {
        throw Exception('Login failed.');
      }

      final profile = await AuthService.getProfile(user.id);

      if (profile == null) {
        await AuthService.signOut();

        throw Exception('No profile was found for this account.');
      }

      final name = profile['name'] as String;

      final role = profile['role'] as String;

      if (!mounted) return;

      if (role == 'owner') {
        Navigator.pushReplacement(
          context,

          MaterialPageRoute(builder: (_) => const OwnerMainScreen()),
        );
      } else if (role == 'salesman') {
        Navigator.pushReplacement(
          context,

          MaterialPageRoute(builder: (_) => SalesmanHome(userName: name)),
        );
      } else {
        await AuthService.signOut();

        throw Exception('This account has an invalid role.');
      }
    } on AuthException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> registerCompany() async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            RegisterCompanyScreen(initialEmail: emailController.text.trim()),
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final slide = Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation);
          final previous =
              Tween<Offset>(begin: Offset.zero, end: const Offset(-0.18, 0))
                  .chain(CurveTween(curve: Curves.easeOutCubic))
                  .animate(secondaryAnimation);
          return SlideTransition(
            position: previous,
            child: SlideTransition(position: slide, child: child),
          );
        },
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 8,
              right: 16,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_outlined, size: 17),
                label: Text(
                  _formatBusinessDate(BusinessDateService.selectedDate.value),
                ),
                onPressed: isLoading ? null : _pickBusinessDate,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 42),
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),

                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),

                    child: Column(
                      children: [
                        // ------------------------------------------------

                        // LOGO

                        // ------------------------------------------------
                        Container(
                          width: 78,

                          height: 78,

                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,

                              end: Alignment.bottomRight,

                              colors: [colors.primary, colors.secondary],
                            ),

                            borderRadius: BorderRadius.circular(22),

                            boxShadow: [
                              BoxShadow(
                                color: colors.primary.withValues(alpha: 0.22),

                                blurRadius: 25,

                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),

                          child: const Icon(
                            Icons.account_balance_wallet_rounded,

                            color: Colors.white,

                            size: 38,
                          ),
                        ),

                        const SizedBox(height: 22),

                        const Text(
                          'Business Payment',

                          style: TextStyle(
                            fontSize: 30,

                            fontWeight: FontWeight.w800,

                            letterSpacing: -0.8,
                          ),
                        ),

                        const SizedBox(height: 7),

                        Text(
                          'Sign in to continue',

                          style: TextStyle(
                            color: colors.onSurfaceVariant,

                            fontSize: 14,
                          ),
                        ),

                        const SizedBox(height: 34),

                        // ------------------------------------------------

                        // LOGIN CARD

                        // ------------------------------------------------
                        Container(
                          padding: const EdgeInsets.all(22),

                          decoration: BoxDecoration(
                            color: colors.surface,

                            borderRadius: BorderRadius.circular(22),

                            border: Border.all(color: colors.outlineVariant),

                            boxShadow: isDark
                                ? null
                                : [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.04,
                                      ),

                                      blurRadius: 25,

                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                          ),

                          child: Column(
                            children: [
                              TextField(
                                controller: emailController,

                                keyboardType: TextInputType.emailAddress,

                                decoration: const InputDecoration(
                                  labelText: 'Email',

                                  prefixIcon: Icon(Icons.email_outlined),
                                ),
                              ),

                              const SizedBox(height: 14),

                              TextField(
                                controller: passwordController,

                                obscureText: obscurePassword,

                                decoration: InputDecoration(
                                  labelText: 'Password',

                                  prefixIcon: const Icon(
                                    Icons.lock_outline_rounded,
                                  ),

                                  suffixIcon: IconButton(
                                    onPressed: () {
                                      setState(() {
                                        obscurePassword = !obscurePassword;
                                      });
                                    },

                                    icon: Icon(
                                      obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(height: 20),

                              SizedBox(
                                width: double.infinity,

                                height: 52,

                                child: ElevatedButton(
                                  onPressed: isLoading ? null : login,

                                  child: isLoading
                                      ? const SizedBox(
                                          width: 22,

                                          height: 22,

                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                          ),
                                        )
                                      : const Text('Login'),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: isLoading ? null : registerCompany,
                                child: const Text('Register a new company'),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 24),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,

                          children: [
                            Icon(
                              Icons.verified_user_outlined,

                              size: 14,

                              color: colors.onSurfaceVariant,
                            ),

                            const SizedBox(width: 6),

                            Text(
                              'Secure business account',

                              style: TextStyle(
                                fontSize: 12,

                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBusinessDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  Future<void> _pickBusinessDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: BusinessDateService.selectedDate.value,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, now.month, now.day),
    );
    if (picked != null) await BusinessDateService.setDate(picked);
    if (mounted) setState(() {});
  }
}

class RegisterCompanyScreen extends StatefulWidget {
  final String initialEmail;

  const RegisterCompanyScreen({super.key, this.initialEmail = ''});

  @override
  State<RegisterCompanyScreen> createState() => _RegisterCompanyScreenState();
}

class _RegisterCompanyScreenState extends State<RegisterCompanyScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _company;
  late final TextEditingController _owner;
  late final TextEditingController _email;
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _confirmationMessage;

  @override
  void initState() {
    super.initState();
    _company = TextEditingController();
    _owner = TextEditingController();
    _email = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _company.dispose();
    _owner.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final response = await AuthService.registerCompany(
        companyName: _company.text.trim(),
        ownerName: _owner.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      if (response.session == null || response.user == null) {
        setState(() {
          _confirmationMessage =
              'This email is valid. Supabase requires email confirmation before the account can sign in. Check the inbox for ${_email.text.trim()}, confirm it, then return to log in.';
        });
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => OwnerMainScreen(userName: _owner.text.trim()),
        ),
        (route) => false,
      );
    } on AuthException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  InputDecoration _decoration(String label, IconData icon) =>
      InputDecoration(labelText: label, prefixIcon: Icon(icon));

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _loading ? null : () => Navigator.pop(context),
        ),
        title: const Text('Create your business account'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_confirmationMessage != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: colors.primary.withValues(alpha: .25),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.mark_email_read_outlined,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _confirmationMessage!,
                                style: TextStyle(
                                  color: colors.onPrimaryContainer,
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF063D28), Color(0xFF0B6A43)],
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.eco_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                          SizedBox(height: 14),
                          Text(
                            'Welcome to LedgerPro',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Set up your private business workspace and start managing customers, payments, and routes.',
                            style: TextStyle(
                              color: Colors.white70,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Business details',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Your data will be kept in your company workspace.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _company,
                      maxLength: 120,
                      decoration: _decoration(
                        'Company name',
                        Icons.business_rounded,
                      ),
                      validator: (v) =>
                          v!.trim().isEmpty ? 'Enter company name' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _owner,
                      maxLength: 120,
                      decoration: _decoration(
                        'Owner name',
                        Icons.person_outline_rounded,
                      ),
                      validator: (v) =>
                          v!.trim().isEmpty ? 'Enter owner name' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _email,
                      maxLength: 254,
                      keyboardType: TextInputType.emailAddress,
                      decoration: _decoration(
                        'Email address',
                        Icons.email_outlined,
                      ),
                      validator: (v) => v!.trim().isEmpty || !v.contains('@')
                          ? 'Enter a valid email'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _password,
                      maxLength: 128,
                      obscureText: _obscure,
                      decoration:
                          _decoration(
                            'Password (12+ characters)',
                            Icons.lock_outline_rounded,
                          ).copyWith(
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                      validator: (v) =>
                          v!.length < 12 ? 'Use at least 12 characters' : null,
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _loading ? null : _register,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                        label: Text(
                          _loading
                              ? 'Creating workspace...'
                              : 'Create business account',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
