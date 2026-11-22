import 'package:flutter/material.dart';

/// Desktop finish layered over the Sydex theme: the Windows system font and
/// slightly denser tables. Colours, shapes and motion come from
/// `buildSydexTheme` so phone and desktop look the same.
ThemeData workspaceTheme(ThemeData base) {
  final colors = base.colorScheme;
  const font = 'Segoe UI';
  TextStyle? withFont(TextStyle? style) => style?.copyWith(fontFamily: font);
  final text = base.textTheme;
  return base.copyWith(
    textTheme: text.copyWith(
      displaySmall: withFont(text.displaySmall),
      headlineMedium: withFont(text.headlineMedium),
      headlineSmall: withFont(text.headlineSmall),
      titleLarge: withFont(text.titleLarge),
      titleMedium: withFont(text.titleMedium),
      titleSmall: withFont(text.titleSmall),
      bodyLarge: withFont(text.bodyLarge),
      bodyMedium: withFont(text.bodyMedium),
      bodySmall: withFont(text.bodySmall),
      labelLarge: withFont(text.labelLarge),
      labelMedium: withFont(text.labelMedium),
      labelSmall: withFont(text.labelSmall),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: withFont(base.appBarTheme.titleTextStyle),
    ),
    dataTableTheme: base.dataTableTheme.copyWith(
      headingRowHeight: 44,
      dataRowMinHeight: 52,
      dataRowMaxHeight: 64,
      horizontalMargin: 20,
      columnSpacing: 28,
      dataRowColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.selected)
            ? colors.onSurface.withValues(alpha: .04)
            : null,
      ),
    ),
  );
}

/// Kept for compatibility with screens that reference it directly.
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
