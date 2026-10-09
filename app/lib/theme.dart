import 'package:flutter/material.dart';

/// Single source of truth for the black minimalist theme.
/// Flat near-black, no gradients, one accent. Elevation via bg steps.
abstract final class AppTokens {
  static const base = Color(0xFF0E0E10);
  static const surface = Color(0xFF171719);
  static const elevated = Color(0xFF1F1F23);
  static const lineSoft = Color(0x12FFFFFF);
  static const lineMed = Color(0x24FFFFFF);
  static const text = Color(0xFFF4F4F5);
  static const textDim = Color(0xA6F4F4F5);
  static const textFaint = Color(0x80F4F4F5);
  static const accent = Color(0xFF34D399);
  static const danger = Color(0xFFF87171);
}

abstract final class AppTheme {
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      surface: AppTokens.base,
      primary: AppTokens.accent,
      onSurface: AppTokens.text,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppTokens.base,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppTokens.base,
        foregroundColor: AppTokens.text,
        elevation: 0,
      ),
      dividerColor: AppTokens.lineSoft,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppTokens.elevated,
        hintStyle: const TextStyle(color: AppTokens.textFaint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTokens.lineMed),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTokens.lineMed),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTokens.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppTokens.text),
        bodySmall: TextStyle(color: AppTokens.textDim),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppTokens.elevated,
        contentTextStyle: const TextStyle(color: AppTokens.text, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTokens.lineMed),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: AppTokens.surface,
        selectedColor: Color(0x3334D399),
        side: BorderSide(color: AppTokens.lineMed),
        labelStyle: TextStyle(color: AppTokens.textDim, fontSize: 12),
      ),
    );
  }
}
