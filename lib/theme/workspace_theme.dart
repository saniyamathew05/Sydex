import 'package:flutter/material.dart';

/// Shared desktop finish, layered over the existing semantic application theme.
ThemeData workspaceTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final colors = base.colorScheme.copyWith(
    surface: dark ? const Color(0xFF20272B) : Colors.white,
    surfaceContainerLowest: dark
        ? const Color(0xFF171D20)
        : const Color(0xFFF6F7F5),
    surfaceContainerLow: dark
        ? const Color(0xFF1C2327)
        : const Color(0xFFFAFBF9),
    surfaceContainer: dark ? const Color(0xFF252D32) : const Color(0xFFF1F4F1),
    surfaceContainerHigh: dark
        ? const Color(0xFF2B3439)
        : const Color(0xFFEBEFEB),
    surfaceContainerHighest: dark
        ? const Color(0xFF333E44)
        : const Color(0xFFE4EAE5),
    outlineVariant: dark ? const Color(0xFF364147) : const Color(0xFFDFE5E0),
    onSurface: dark ? const Color(0xFFF0F4F2) : const Color(0xFF202B27),
    onSurfaceVariant: dark ? const Color(0xFFAFBDB8) : const Color(0xFF68766F),
  );
  final radius = BorderRadius.circular(10);
  final button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 42)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius)),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    animationDuration: const Duration(milliseconds: 140),
  );
  return base.copyWith(
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surfaceContainerLowest,
    textTheme: base.textTheme
        .apply(
          fontFamily: 'Segoe UI',
          bodyColor: colors.onSurface,
          displayColor: colors.onSurface,
        )
        .merge(
          const TextTheme(
            bodyMedium: TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            bodyLarge: TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        ...base.pageTransitionsTheme.builders,
        TargetPlatform.windows: const WorkspaceRouteTransition(),
        TargetPlatform.linux: const WorkspaceRouteTransition(),
        TargetPlatform.macOS: const WorkspaceRouteTransition(),
      },
    ),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleSpacing: 24,
      titleTextStyle: TextStyle(
        fontFamily: 'Segoe UI',
        color: colors.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.merge(button),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.merge(button),
    ),
    cardTheme: base.cardTheme.copyWith(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: colors.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
    ),
    dataTableTheme: base.dataTableTheme.copyWith(
      headingRowHeight: 44,
      dataRowMinHeight: 52,
      dataRowMaxHeight: 64,
      horizontalMargin: 20,
      columnSpacing: 28,
      dividerThickness: .6,
      headingRowColor: WidgetStatePropertyAll(colors.surfaceContainerLow),
      dataRowColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.selected)
            ? colors.primary.withValues(alpha: .07)
            : null,
      ),
      headingTextStyle: TextStyle(
        color: colors.onSurfaceVariant,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        fontFamily: 'Segoe UI',
      ),
      dataTextStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 13,
        fontFamily: 'Segoe UI',
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      iconColor: colors.onSurfaceVariant,
      textColor: colors.onSurface,
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: colors.surface,
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(color: colors.surface),
    dividerTheme: base.dividerTheme.copyWith(color: colors.outlineVariant),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(6),
      thickness: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ? 8 : 5,
      ),
    ),
  );
}

class WorkspaceRouteTransition extends PageTransitionsBuilder {
  const WorkspaceRouteTransition();

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
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .012),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }
}
