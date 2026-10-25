import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colours from the SecureShe Figma design (theme.css).
///
/// Brand and status colours are the same in both modes; surfaces and text
/// change. Read the mode-specific ones with `context.ss`.
class AppColors {
  static const primary = Color(0xFFFF1493);
  static const primaryDark = Color(0xFFC0106F);
  static const destructive = Color(0xFFFF3B30);
  static const destructiveDark = Color(0xFFD32F2F);
  static const warning = Color(0xFFFFBE0B);
  static const success = Color(0xFF28C76F);
  static const successDark = Color(0xFF1AAD5C);
  static const violet = Color(0xFF6C5CE7);
  static const lavender = Color(0xFFA78BFA);

  static const primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryDark],
  );

  static const dangerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [destructive, destructiveDark],
  );

  static const successGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [success, Color(0xFF20A85A)],
  );

  // Kept for screens written before the redesign.
  static const navy = Color(0xFF1E2761);
  static const coral = primary;
  static const iceBlue = Color(0xFFCADCFC);
  static const background = Color(0xFF08080F);
}

/// Mode-specific colours (dark = "Night Mode", light = "Day Mode").
@immutable
class SSColors extends ThemeExtension<SSColors> {
  const SSColors({
    required this.isDark,
    required this.foreground,
    required this.muted,
    required this.mutedForeground,
    required this.card,
    required this.cardSolid,
    required this.border,
    required this.input,
    required this.glass,
    required this.screen,
    required this.overlay,
    required this.navBar,
    required this.warning,
    required this.success,
    required this.sheet,
  });

  final bool isDark;
  final Color foreground;
  final Color muted;
  final Color mutedForeground;

  /// Translucent card over the background image.
  final Color card;

  /// Opaque version, for sheets and dialogs that cover content.
  final Color cardSolid;
  final Color border;
  final Color input;

  /// Header / sticky bar background.
  final Color glass;

  /// Colour under the background image.
  final Color screen;

  /// Tint laid over the background image.
  final Color overlay;
  final Color navBar;
  final Color warning;
  final Color success;
  final Color sheet;

  static const dark = SSColors(
    isDark: true,
    foreground: Color(0xFFF5F5F7),
    muted: Color(0xFF2A2A38),
    mutedForeground: Color(0xFF9CA3AF),
    card: Color(0xB8120E1E), // rgba(18,14,30,0.72)
    cardSolid: Color(0xFF15111F),
    border: Color(0x1AFFFFFF),
    input: Color(0x14FFFFFF),
    glass: Color(0xC7080512), // rgba(8,5,18,0.78)
    screen: Color(0xFF08080F),
    overlay: Color(0x7306040E), // rgba(6,4,14,0.45)
    navBar: Color(0xBF0A0614), // rgba(10,6,20,0.75)
    warning: Color(0xFFFFBE0B),
    success: Color(0xFF28C76F),
    sheet: Color(0xFA0C0816),
  );

  static const light = SSColors(
    isDark: false,
    foreground: Color(0xFF1A0820),
    muted: Color(0xFFEDE5F5),
    mutedForeground: Color(0xFF7C6A8A),
    card: Color(0xD9FFFFFF), // rgba(255,255,255,0.85)
    cardSolid: Color(0xFFFFFFFF),
    border: Color(0x1A000000),
    input: Color(0x0F000000),
    glass: Color(0xD1FFFCFF), // rgba(255,252,255,0.82)
    screen: Color(0xFFF9F0FF),
    overlay: Color(0xB8FFF0FA), // rgba(255,240,250,0.72)
    navBar: Color(0xE0FFFCFF),
    warning: Color(0xFFE09900),
    success: Color(0xFF1AAD5C),
    sheet: Color(0xFAFFFFFF),
  );

  @override
  SSColors copyWith() => this;

  @override
  SSColors lerp(ThemeExtension<SSColors>? other, double t) {
    if (other is! SSColors) return this;
    return t < 0.5 ? this : other;
  }
}

extension SSThemeContext on BuildContext {
  SSColors get ss => Theme.of(this).extension<SSColors>()!;
}

ThemeData _buildTheme(SSColors c) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: c.isDark ? Brightness.dark : Brightness.light,
  );

  final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: c.foreground,
    displayColor: c.foreground,
  );

  return base.copyWith(
    extensions: [c],
    scaffoldBackgroundColor: c.screen,
    textTheme: textTheme,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: c.isDark ? Brightness.dark : Brightness.light,
    ).copyWith(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.primary,
      error: AppColors.destructive,
      surface: c.cardSolid,
      onSurface: c.foreground,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.glass,
      foregroundColor: c.foreground,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.inter(
        color: c.foreground,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.cardSolid,
      contentTextStyle: GoogleFonts.inter(color: c.foreground, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.cardSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.sheet,
      modalBackgroundColor: c.sheet,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.input,
      hintStyle: TextStyle(color: c.mutedForeground, fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.foreground,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.primary),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
    ),
    dividerColor: c.border,
  );
}

final ThemeData darkTheme = _buildTheme(SSColors.dark);
final ThemeData lightTheme = _buildTheme(SSColors.light);

/// Kept so older imports of `appTheme` keep working.
final ThemeData appTheme = darkTheme;
