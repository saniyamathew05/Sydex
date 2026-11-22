import 'package:flutter/material.dart';

/// Sydex visual tokens (minimal design system; see sydex_theme.dart).
/// Use these constants for new screens so the brand stays consistent.
abstract final class HorizonTokens {
  static const navy = Color(0xFF141414);
  static const navySoft = Color(0xFF2A2A2A);
  static const green = Color(0xFF141414);
  static const greenBright = Color(0xFF3D3A35);
  static const greenSoft = Color(0xFFF1F0ED);
  static const background = Color(0xFFF7F7F5);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE8E6E1);
  static const text = Color(0xFF141414);
  static const muted = Color(0xFF66625C);
  static const success = Color(0xFF141414);
  static const successSoft = Color(0xFFF1F0ED);
  static const danger = Color(0xFFA61B1B);
  static const dangerSoft = Color(0xFFFBEAEA);
  static const warning = Color(0xFF8A5300);
  static const warningSoft = Color(0xFFFBF1E1);

  static const radiusSmall = 10.0;
  static const radiusCard = 16.0;
  static const radiusLarge = 22.0;
  static const pagePadding = 20.0;
  static const spacing = <double>[4, 8, 12, 16, 20, 24, 32, 40, 48];

  static TextTheme textTheme(TextTheme base) => base.copyWith(
    displaySmall: base.displaySmall?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
      height: 1.15,
    ),
    headlineSmall: base.headlineSmall?.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    titleLarge: base.titleLarge?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w700,
    ),
    titleMedium: base.titleMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.35),
    labelMedium: base.labelMedium?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    ),
  );
}
