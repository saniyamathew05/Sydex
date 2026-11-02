import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/owner/owner_main_screen.dart';

import 'screens/salesman/salesman_home.dart';

import 'services/theme_controller.dart';

import 'services/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isWindowsApp =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  if (isWindowsApp) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

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

  await ThemeController.loadTheme();

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
    with WidgetsBindingObserver, WindowListener {
  bool _isClosing = false;
  Future<void>? _closeSignOut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_isClosing) return;
    _isClosing = true;
    await _signOutOnClose();
    await windowManager.setPreventClose(false);
    await windowManager.close();
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

      builder: (context, themeMode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,

          title: 'LedgerPro',

          themeMode: themeMode,

          theme: _buildLightTheme(),

          darkTheme: _buildDarkTheme(),

          home: const AuthGate(),
        );
      },
    );
  }

  // ==========================================================

  // LIGHT THEME

  // ==========================================================

  ThemeData _buildLightTheme() {
    const primary = Color(0xFF4F2BCB);

    const secondary = Color(0xFF6D4AFF);

    const background = Color(0xFFF5F6FC);

    const surface = Color(0xFFFFFFFF);

    const border = Color(0xFFE5E7F2);

    const textPrimary = Color(0xFF11152E);

    const textSecondary = Color(0xFF68708B);

    final colorScheme = ColorScheme.light(
      primary: primary,

      onPrimary: Colors.white,

      primaryContainer: const Color(0xFFEAE5FF),

      onPrimaryContainer: const Color(0xFF2D176F),

      secondary: secondary,

      onSecondary: Colors.white,

      secondaryContainer: const Color(0xFFEAE5FF),

      onSecondaryContainer: const Color(0xFF352079),

      surface: surface,

      onSurface: textPrimary,

      surfaceContainerLowest: Colors.white,

      surfaceContainerLow: const Color(0xFFFCFCFF),

      surfaceContainer: const Color(0xFFF2F3FA),

      surfaceContainerHigh: const Color(0xFFEDEEFF),

      surfaceContainerHighest: const Color(0xFFE4E6F3),

      onSurfaceVariant: textSecondary,

      outline: const Color(0xFFC9CBE0),

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

      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),

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
          color: Color(0xFF11152E),
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
        backgroundColor: const Color(0xFFF2F3FA),
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
          borderRadius: BorderRadius.circular(18),

          side: const BorderSide(color: border),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,

        fillColor: const Color(0xFFF8F8FD),

        floatingLabelBehavior: FloatingLabelBehavior.auto,

        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,

          vertical: 15,
        ),

        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: border),
        ),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: border),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: primary, width: 2),
        ),

        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: Color(0xFFDC2626)),
        ),

        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

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

          disabledForegroundColor: const Color(0xFF68708B),

          elevation: 0,

          minimumSize: const Size(0, 50),

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
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

      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,

        foregroundColor: Colors.white,

        elevation: 3,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,

        indicatorColor: const Color(0xFFEAE5FF),

        elevation: 0,

        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              fontSize: 12,

              fontWeight: FontWeight.w700,

              color: primary,
            );
          }

          return const TextStyle(
            fontSize: 12,

            fontWeight: FontWeight.w500,

            color: textSecondary,
          );
        }),

        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: primary);
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

        backgroundColor: const Color(0xFF11152E),

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

      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
    );
  }

  // ==========================================================

  // DARK THEME

  // ==========================================================

  ThemeData _buildDarkTheme() {
    const primary = Color(0xFF9A83FF);

    const secondary = Color(0xFF7C5CFA);

    const background = Color(0xFF0D1026);

    const surface = Color(0xFF151A35);

    const border = Color(0xFF343957);

    const textPrimary = Color(0xFFF2F3FA);

    const textSecondary = Color(0xFFC0C5DF);

    final colorScheme = ColorScheme.dark(
      primary: primary,

      onPrimary: const Color(0xFF21115A),

      primaryContainer: const Color(0xFF302064),

      onPrimaryContainer: const Color(0xFFEAE5FF),

      secondary: secondary,

      onSecondary: const Color(0xFF21115A),

      secondaryContainer: const Color(0xFF302064),

      onSecondaryContainer: const Color(0xFFEAE5FF),

      surface: surface,

      onSurface: textPrimary,

      surfaceContainerLowest: const Color(0xFF0D1026),

      surfaceContainerLow: const Color(0xFF11152E),

      surfaceContainer: const Color(0xFF171936),

      surfaceContainerHigh: const Color(0xFF202544),

      surfaceContainerHighest: const Color(0xFF292F50),

      onSurfaceVariant: textSecondary,

      outline: const Color(0xFF747B9D),

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

      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),

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
          color: Color(0xFF292F50),
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
        backgroundColor: const Color(0xFF202544),
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
          borderRadius: BorderRadius.circular(18),

          side: const BorderSide(color: border),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,

        fillColor: const Color(0xFF171936),

        floatingLabelBehavior: FloatingLabelBehavior.auto,

        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,

          vertical: 15,
        ),

        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: border),
        ),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: border),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: primary, width: 2),
        ),

        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: Color(0xFFF87171)),
        ),

        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),

          borderSide: const BorderSide(color: Color(0xFFF87171), width: 2),
        ),

        labelStyle: const TextStyle(color: textSecondary),

        hintStyle: const TextStyle(color: Color(0xFFB7BED8)),

        prefixIconColor: textSecondary,

        suffixIconColor: textSecondary,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,

          foregroundColor: const Color(0xFF21115A),

          disabledBackgroundColor: const Color(0xFF343957),

          disabledForegroundColor: const Color(0xFFCFD3E5),

          elevation: 0,

          minimumSize: const Size(0, 50),

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
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

      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,

        foregroundColor: Color(0xFF21115A),

        elevation: 3,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,

        indicatorColor: const Color(0xFF302064),

        elevation: 0,

        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              fontSize: 12,

              fontWeight: FontWeight.w700,

              color: primary,
            );
          }

          return const TextStyle(
            fontSize: 12,

            fontWeight: FontWeight.w500,

            color: textSecondary,
          );
        }),

        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: primary);
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

        backgroundColor: const Color(0xFF292F50),

        contentTextStyle: const TextStyle(
          color: Color(0xFFF2F3FA),

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

      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
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

  @override
  void initState() {
    super.initState();

    _checkCurrentUser();
  }

  Future<void> _checkCurrentUser() async {
    final user = AuthService.currentUser;

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

    if (email.isEmpty || password.isEmpty) {
      _showError('Please enter email and password.');

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
                                color: Colors.black.withValues(alpha: 0.04),

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

                            prefixIcon: const Icon(Icons.lock_outline_rounded),

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
    );
  }
}
