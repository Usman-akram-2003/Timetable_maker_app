import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central design system for Timetable Maker
/// Supports both Dark (navy/cyan glassmorphism) and Light themes.
class AppTheme {
  // ── Dark palette ───────────────────────────────────────────────────────────
  static const Color bgDeep        = Color(0xFF0B1120);   // deep navy
  static const Color bgMid         = Color(0xFF111827);   // sidebar/panel
  static const Color bgCard        = Color(0xFF1C2A40);   // cards — clearly lighter than bg
  static const Color bgGlass       = Color(0x22FFFFFF);
  static const Color bgGlassBorder = Color(0x44FFFFFF);

  static const Color accentCyan    = Color(0xFF06B6D4);
  static const Color accentTeal    = Color(0xFF14B8A6);
  static const Color accentViolet  = Color(0xFF8B5CF6);
  static const Color accentAmber   = Color(0xFFF59E0B);

  static const Color textPrimary   = Color(0xFFF1F5F9);   // near-white
  static const Color textSecondary = Color(0xFFCBD5E1);   // slate-300 — much brighter
  static const Color textMuted     = Color(0xFF64748B);   // slate-500

  static const Color divider       = Color(0xFF253348);   // stronger visible border
  static const Color success       = Color(0xFF10B981);
  static const Color error         = Color(0xFFEF4444);

  // ── Light palette (same accents, light surface) ───────────────────────────
  static const Color lightBg       = Color(0xFFF0F4F8);
  static const Color lightBgMid    = Color(0xFFFFFFFF);
  static const Color lightBgCard   = Color(0xFFFFFFFF);
  static const Color lightDivider  = Color(0xFFE2E8F0);
  static const Color lightText     = Color(0xFF1E293B);
  static const Color lightTextSec  = Color(0xFF64748B);
  static const Color lightTextMut  = Color(0xFF94A3B8);

  // ── Gradients ─────────────────────────────────────────────────────────────
  static const LinearGradient bgGradient = LinearGradient(
    colors: [Color(0xFF0B1120), Color(0xFF111827), Color(0xFF0D1B2E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cyanGradient = LinearGradient(
    colors: [Color(0xFF06B6D4), Color(0xFF0891B2)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient tealGradient = LinearGradient(
    colors: [Color(0xFF14B8A6), Color(0xFF0D9488)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient violetGradient = LinearGradient(
    colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF0891B2), Color(0xFF6D28D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── BoxDecorations ────────────────────────────────────────────────────────
  static BoxDecoration glassCard({double radius = 20, Color? borderColor}) {
    return BoxDecoration(
      color: bgGlass,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor ?? bgGlassBorder, width: 1.0),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 8)),
      ],
    );
  }

  static BoxDecoration solidCard({double radius = 20}) {
    return BoxDecoration(
      color: bgCard,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: divider, width: 1.0),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 20, offset: const Offset(0, 6)),
      ],
    );
  }

  static BoxDecoration glowCard(Color glowColor, {double radius = 20}) {
    return BoxDecoration(
      color: bgCard,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: glowColor.withValues(alpha: 0.3), width: 1.0),
      boxShadow: [
        BoxShadow(color: glowColor.withValues(alpha: 0.12), blurRadius: 28, spreadRadius: 0, offset: const Offset(0, 4)),
        BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 4)),
      ],
    );
  }

  // Light-mode equivalents (softer shadows, white cards)
  static BoxDecoration glassCardLight({double radius = 20}) {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: lightDivider, width: 1.0),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 16, offset: const Offset(0, 4)),
      ],
    );
  }

  static BoxDecoration solidCardLight({double radius = 20}) {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: lightDivider, width: 1.0),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 3)),
      ],
    );
  }

  static BoxDecoration glowCardLight(Color glowColor, {double radius = 20}) {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: glowColor.withValues(alpha: 0.2), width: 1.0),
      boxShadow: [
        BoxShadow(color: glowColor.withValues(alpha: 0.10), blurRadius: 18, offset: const Offset(0, 4)),
        BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
      ],
    );
  }

  // ── Dark Material Theme ───────────────────────────────────────────────────
  static ThemeData darkTheme(BuildContext context) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary:   accentCyan,
        secondary: accentTeal,
        tertiary:  accentViolet,
        surface:   bgCard,
        onSurface: textPrimary,
        outline:   divider,
      ),
      scaffoldBackgroundColor: bgDeep,
      textTheme: GoogleFonts.plusJakartaSansTextTheme(Theme.of(context).textTheme)
          .apply(bodyColor: textPrimary, displayColor: textPrimary),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bgMid,
        indicatorColor: accentCyan.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.plusJakartaSans(color: accentCyan, fontSize: 11, fontWeight: FontWeight.w700);
          }
          return GoogleFonts.plusJakartaSans(color: textMuted, fontSize: 11, fontWeight: FontWeight.w500);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: accentCyan, size: 22);
          }
          return const IconThemeData(color: Color(0xFF475569), size: 22);
        }),
      ),
    );
  }

  // ── Light Material Theme ──────────────────────────────────────────────────
  static ThemeData lightTheme(BuildContext context) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary:   accentCyan,
        secondary: accentTeal,
        tertiary:  accentViolet,
        surface:   lightBgCard,
        onSurface: lightText,
        outline:   lightDivider,
      ),
      scaffoldBackgroundColor: lightBg,
      textTheme: GoogleFonts.plusJakartaSansTextTheme(Theme.of(context).textTheme)
          .apply(bodyColor: lightText, displayColor: lightText),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: lightBgMid,
        indicatorColor: accentCyan.withValues(alpha: 0.15),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.plusJakartaSans(color: accentCyan, fontSize: 11, fontWeight: FontWeight.w700);
          }
          return GoogleFonts.plusJakartaSans(color: lightTextMut, fontSize: 11, fontWeight: FontWeight.w500);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: accentCyan, size: 22);
          }
          return IconThemeData(color: lightTextMut, size: 22);
        }),
      ),
    );
  }

  // Keep old name as redirect so nothing else breaks
  static ThemeData materialTheme(BuildContext context) => darkTheme(context);
}
