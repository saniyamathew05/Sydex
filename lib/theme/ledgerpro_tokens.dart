import 'package:flutter/material.dart';

/// LedgerPro visual tokens based on the supplied dashboard reference.
/// Use these constants for new screens so the brand stays consistent.
abstract final class LedgerProTokens {
  static const navy = Color(0xFF064632);
  static const navySoft = Color(0xFF075C42);
  static const green = Color(0xFF075C42);
  static const greenBright = Color(0xFF087553);
  static const greenSoft = Color(0xFFE5EEE7);
  static const background = Color(0xFFFAFAF7);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFDEE5DD);
  static const text = Color(0xFF17251E);
  static const muted = Color(0xFF65736B);
  static const success = Color(0xFF16845A);
  static const successSoft = Color(0xFFE5EEE7);
  static const danger = Color(0xFFC44747);
  static const dangerSoft = Color(0xFFFCEBEB);
  static const warning = Color(0xFFB7791F);
  static const warningSoft = Color(0xFFFFF4DE);

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
