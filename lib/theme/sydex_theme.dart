import 'package:flutter/material.dart';

/// Sydex minimal design system.
///
/// Flat colour, hairline borders and quiet motion. Ink (#141414) is the
/// primary colour; green is reserved for money coming in, amber for pending
/// and red for refused/bounced/destructive. Every screen picks these up from
/// the theme, so no screen needs hard-coded colours.
abstract final class SydexColors {
  static const ink = Color(0xFF141414);
  static const paper = Color(0xFFF7F7F5);
  static const surface = Color(0xFFFFFFFF);
  static const tile = Color(0xFFF1F0ED);
  static const line = Color(0xFFE8E6E1);
  static const lineStrong = Color(0xFFCFCBC4);
  static const muted = Color(0xFF66625C);
  static const faint = Color(0xFF8C877F);
  static const money = Color(0xFF141414);
  static const moneySoft = Color(0xFFF1F0ED);
  static const pending = Color(0xFF8A5300);
  static const pendingSoft = Color(0xFFFBF1E1);
  static const danger = Color(0xFFA61B1B);
  static const dangerSoft = Color(0xFFFBEAEA);

  static const darkPaper = Color(0xFF0F0F0F);
  static const darkSurface = Color(0xFF181818);
  static const darkTile = Color(0xFF222222);
  static const darkLine = Color(0xFF2C2C2C);
  static const darkText = Color(0xFFF2F1EE);
  static const darkMuted = Color(0xFFA6A29B);

  /// Solid background for summary cards that draw white text.
  static Color hero(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF262626)
      : ink;
}

const _ease = Curves.easeOutCubic;

ThemeData buildSydexTheme(Brightness brightness, Color accent) {
  final dark = brightness == Brightness.dark;
  final isInk = accent.toARGB32() == SydexColors.ink.toARGB32();

  // Primary: ink by default. On dark backgrounds ink turns into near-white so
  // primary buttons keep strong contrast. Other accent choices still work.
  // In dark mode the ink accent becomes a soft grey so both kinds of existing
  // usage stay readable: primary as text on dark surfaces, and white text
  // drawn on primary-coloured fills.
  final primary = dark
      ? (isInk ? const Color(0xFF9C978F) : Color.lerp(accent, Colors.white, .42)!)
      : accent;
  final onPrimary = dark ? SydexColors.ink : Colors.white;

  final paper = dark ? SydexColors.darkPaper : SydexColors.paper;
  final surface = dark ? SydexColors.darkSurface : SydexColors.surface;
  final tile = dark ? SydexColors.darkTile : SydexColors.tile;
  final line = dark ? SydexColors.darkLine : SydexColors.line;
  final text = dark ? SydexColors.darkText : SydexColors.ink;
  final muted = dark ? SydexColors.darkMuted : SydexColors.muted;

  final colors = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: tile,
    onPrimaryContainer: text,
    // Money and "positive" states stay neutral: weight, not colour, marks them.
    secondary: text,
    onSecondary: dark ? SydexColors.ink : Colors.white,
    secondaryContainer: tile,
    onSecondaryContainer: text,
    tertiary: dark ? const Color(0xFFE0B36A) : SydexColors.pending,
    onTertiary: dark ? SydexColors.ink : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF2E2414) : SydexColors.pendingSoft,
    onTertiaryContainer: dark ? const Color(0xFFF0D3A0) : SydexColors.pending,
    error: dark ? const Color(0xFFF08A8A) : SydexColors.danger,
    onError: dark ? SydexColors.ink : Colors.white,
    errorContainer: dark ? const Color(0xFF3A1616) : SydexColors.dangerSoft,
    onErrorContainer: dark ? const Color(0xFFF6C2C2) : SydexColors.danger,
    surface: surface,
    onSurface: text,
    onSurfaceVariant: muted,
    surfaceContainerLowest: paper,
    surfaceContainerLow: dark ? const Color(0xFF141414) : const Color(0xFFFBFBFA),
    surfaceContainer: tile,
    surfaceContainerHigh: dark ? const Color(0xFF262626) : const Color(0xFFEDECE8),
    surfaceContainerHighest: dark ? const Color(0xFF2E2E2E) : const Color(0xFFE7E5E0),
    outline: dark ? const Color(0xFF3A3A3A) : SydexColors.lineStrong,
    outlineVariant: line,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: dark ? SydexColors.darkText : SydexColors.ink,
    onInverseSurface: dark ? SydexColors.ink : Colors.white,
    inversePrimary: dark ? SydexColors.ink : Colors.white,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    visualDensity: VisualDensity.standard,
  );

  final textTheme = base.textTheme
      .apply(bodyColor: text, displayColor: text)
      .copyWith(
        displaySmall: base.textTheme.displaySmall?.copyWith(
          fontSize: 34,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.0,
          height: 1.1,
          color: text,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.8,
          color: text,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.6,
          color: text,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          color: text,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 15,
          height: 1.45,
          color: text,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.45,
          color: text,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          height: 1.4,
          color: muted,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
          color: muted,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.6,
          color: muted,
        ),
      );

  RoundedRectangleBorder rounded(double r, {Color? side}) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r),
        side: side == null ? BorderSide.none : BorderSide(color: side),
      );

  const buttonSize = WidgetStatePropertyAll(Size(64, 50));
  const buttonPadding = WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 20, vertical: 14),
  );
  const buttonText = WidgetStatePropertyAll(
    TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0),
  );
  final filled = ButtonStyle(
    minimumSize: buttonSize,
    padding: buttonPadding,
    textStyle: buttonText,
    elevation: const WidgetStatePropertyAll(0),
    shape: WidgetStatePropertyAll(rounded(14)),
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled)
          ? tile
          : s.contains(WidgetState.pressed)
          ? Color.lerp(primary, dark ? Colors.black : Colors.white, .14)
          : primary,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? muted : onPrimary,
    ),
    overlayColor: WidgetStatePropertyAll(onPrimary.withValues(alpha: .08)),
    animationDuration: const Duration(milliseconds: 160),
  );
  final outlined = ButtonStyle(
    minimumSize: buttonSize,
    padding: buttonPadding,
    textStyle: buttonText,
    elevation: const WidgetStatePropertyAll(0),
    shape: WidgetStatePropertyAll(rounded(14)),
    side: WidgetStateProperty.resolveWith(
      (s) => BorderSide(
        color: s.contains(WidgetState.disabled) ? line : colors.outline,
      ),
    ),
    backgroundColor: WidgetStatePropertyAll(surface),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? muted : text,
    ),
    overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .05)),
  );

  return base.copyWith(
    colorScheme: colors,
    scaffoldBackgroundColor: paper,
    canvasColor: paper,
    dividerColor: line,
    splashFactory: InkSparkle.splashFactory,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    iconTheme: IconThemeData(color: text, size: 22),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SydexRouteTransition(),
        TargetPlatform.iOS: SydexRouteTransition(),
        TargetPlatform.windows: SydexRouteTransition(),
        TargetPlatform.linux: SydexRouteTransition(),
        TargetPlatform.macOS: SydexRouteTransition(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: paper,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 20,
      iconTheme: IconThemeData(color: text),
      titleTextStyle: textTheme.titleLarge,
      shape: Border(bottom: BorderSide(color: line.withValues(alpha: 0))),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      surfaceTintColor: Colors.transparent,
      shape: rounded(18, side: line),
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(style: filled),
    elevatedButtonTheme: ElevatedButtonThemeData(style: filled),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(text),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        shape: WidgetStatePropertyAll(rounded(12)),
        overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .05)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(rounded(12)),
        overlayColor: WidgetStatePropertyAll(text.withValues(alpha: .06)),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: onPrimary,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: rounded(18),
      extendedTextStyle: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      labelStyle: TextStyle(color: muted, fontSize: 14),
      floatingLabelStyle: TextStyle(color: text, fontWeight: FontWeight.w500),
      hintStyle: TextStyle(color: SydexColors.faint, fontSize: 14),
      prefixIconColor: muted,
      suffixIconColor: muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: text, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.error, width: 1.4),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line.withValues(alpha: .6)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: primary,
      disabledColor: tile,
      checkmarkColor: onPrimary,
      side: BorderSide(color: line),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(
        color: onPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      elevation: 0,
      pressElevation: 0,
      showCheckmark: false,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(rounded(12)),
        side: WidgetStatePropertyAll(BorderSide(color: line)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? primary : surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? onPrimary : text,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 70,
      indicatorColor: tile,
      indicatorShape: rounded(12),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? text : SydexColors.faint,
          size: 22,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 11,
          fontWeight: s.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? text : SydexColors.faint,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: tile,
      selectedIconTheme: IconThemeData(color: text),
      unselectedIconTheme: const IconThemeData(color: SydexColors.faint),
      selectedLabelTextStyle: TextStyle(
        color: text,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: SydexColors.faint,
        fontSize: 12,
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: surface,
      selectedItemColor: text,
      unselectedItemColor: SydexColors.faint,
      elevation: 0,
      type: BottomNavigationBarType.fixed,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: text,
      unselectedLabelColor: muted,
      indicatorColor: text,
      dividerColor: line,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: text,
      textColor: text,
      tileColor: Colors.transparent,
      shape: rounded(12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      subtitleTextStyle: TextStyle(color: muted, fontSize: 12.5),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: rounded(20, side: line),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: muted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: colors.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: .12),
      shape: rounded(14, side: line),
      textStyle: TextStyle(color: text, fontSize: 14),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded(14, side: line)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? SydexColors.darkText : SydexColors.ink,
      contentTextStyle: TextStyle(
        color: dark ? SydexColors.ink : Colors.white,
        fontSize: 14,
      ),
      actionTextColor: dark ? SydexColors.ink : Colors.white,
      shape: rounded(14),
      elevation: 0,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? SydexColors.darkText : SydexColors.ink,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(
        color: dark ? SydexColors.ink : Colors.white,
        fontSize: 12,
      ),
      waitDuration: const Duration(milliseconds: 400),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: tile,
      circularTrackColor: tile,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? onPrimary : surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary : colors.outline,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(onPrimary),
      side: BorderSide(color: colors.outline, width: 1.5),
      shape: rounded(5),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary : colors.outline,
      ),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: paper,
      headerForegroundColor: text,
      shape: rounded(20, side: line),
      todayBorder: BorderSide(color: text),
      dayForegroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? onPrimary : text,
      ),
      dayBackgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary : null,
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingRowColor: WidgetStatePropertyAll(paper),
      headingTextStyle: TextStyle(
        color: muted,
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        letterSpacing: .6,
      ),
      dataTextStyle: TextStyle(
        color: text,
        fontSize: 13,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      dividerThickness: 1,
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(6),
      thumbColor: WidgetStatePropertyAll(colors.outline),
      thickness: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.hovered) ? 8 : 5,
      ),
    ),
  );
}

/// Quiet page transition: a short fade with an 8 px rise.
class SydexRouteTransition extends PageTransitionsBuilder {
  const SydexRouteTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curve = CurvedAnimation(
      parent: animation,
      curve: _ease,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .015),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }
}
