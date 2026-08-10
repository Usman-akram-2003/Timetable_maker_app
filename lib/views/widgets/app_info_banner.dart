import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../app_theme.dart';

enum AppBannerStyle { info, warning, error, success }

// ─────────────────────────────────────────────────────────────────────────────
// AppInfoBanner
// Themed banner for info / warning / error / success messages.
// ─────────────────────────────────────────────────────────────────────────────
class AppInfoBanner extends StatelessWidget {
  final String title;
  final String? message;
  final AppBannerStyle style;
  final VoidCallback? onDismiss;
  final Widget? trailing;

  const AppInfoBanner({
    super.key,
    required this.title,
    this.message,
    this.style = AppBannerStyle.info,
    this.onDismiss,
    this.trailing,
  });

  static const _meta = {
    AppBannerStyle.info: (
      color: AppTheme.accentCyan,
      icon: Icons.info_rounded,
    ),
    AppBannerStyle.warning: (
      color: AppTheme.accentAmber,
      icon: Icons.warning_amber_rounded,
    ),
    AppBannerStyle.error: (
      color: AppTheme.error,
      icon: Icons.error_rounded,
    ),
    AppBannerStyle.success: (
      color: AppTheme.success,
      icon: Icons.check_circle_rounded,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final m = _meta[style]!;
    final color = m.color;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ts = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(m.icon, color: color, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    color: color,
                    fontSize: 13,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: GoogleFonts.plusJakartaSans(
                      color: isDark
                          ? color.withValues(alpha: .85)
                          : ts,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
          if (onDismiss != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onDismiss,
              child: Icon(Icons.close_rounded, size: 16, color: ts),
            ),
          ],
        ],
      ),
    );
  }
}
