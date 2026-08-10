import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppStatCard
// Animated count-up stat card with gradient icon, glow border, and tap action.
// ─────────────────────────────────────────────────────────────────────────────
class AppStatCard extends StatelessWidget {
  final IconData icon;
  final LinearGradient gradient;
  final Color glow;
  final String label;
  final int value;
  final VoidCallback? onTap;
  final String? subtitle;

  const AppStatCard({
    super.key,
    required this.icon,
    required this.gradient,
    required this.glow,
    required this.label,
    required this.value,
    this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ts = dark ? AppTheme.textSecondary : AppTheme.lightTextSec;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOut,
      builder: (_, v, __) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: dark
              ? AppTheme.glowCard(glow, radius: 14)
              : AppTheme.glowCardLight(glow, radius: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: [
                        BoxShadow(
                          color: glow.withValues(alpha: .4),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Icon(icon, color: Colors.white, size: 16),
                  ),
                  ShaderMask(
                    shaderCallback: (b) => gradient.createShader(b),
                    child: Text(
                      v.toInt().toString(),
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .3,
                  color: ts,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: GoogleFonts.plusJakartaSans(fontSize: 9, color: ts),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 6),
              Container(
                height: 2,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
