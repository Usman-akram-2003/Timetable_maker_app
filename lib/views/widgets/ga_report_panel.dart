import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../app_theme.dart';
import '../../viewmodels/backend_viewmodel.dart';

// ─────────────────────────────────────────────────────────────────────────────
// showGaReportPanel
// Call this after GA finishes. Shows a modal bottom sheet with a full
// clash breakdown, generation count, and a navigate-to-schedule action.
// ─────────────────────────────────────────────────────────────────────────────
void showGaReportPanel(
  BuildContext context,
  GaScheduleResult result, {
  VoidCallback? onViewSchedule,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _GaReportSheet(
      result: result,
      onViewSchedule: onViewSchedule,
    ),
  );
}

class _GaReportSheet extends StatefulWidget {
  final GaScheduleResult result;
  final VoidCallback? onViewSchedule;
  const _GaReportSheet({required this.result, this.onViewSchedule});

  @override
  State<_GaReportSheet> createState() => _GaReportSheetState();
}

class _GaReportSheetState extends State<_GaReportSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tp = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final ts = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final bg = isDark ? AppTheme.bgMid : Colors.white;
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;

    final result = widget.result;
    final allGood = result.totalClashes == 0;

    // Clash category definitions
    final categories = [
      _ClashCategory(
        key: 'H1_teacher_clash',
        label: 'Teacher Clashes',
        icon: Icons.person_off_rounded,
        color: AppTheme.error,
        description: 'Same teacher in two classes at the same time',
      ),
      _ClashCategory(
        key: 'H2_room_clash',
        label: 'Room Clashes',
        icon: Icons.meeting_room_rounded,
        color: const Color(0xFFF97316),
        description: 'Same room booked by two groups at the same time',
      ),
      _ClashCategory(
        key: 'H3_section_clash',
        label: 'Section Clashes',
        icon: Icons.group_off_rounded,
        color: AppTheme.accentAmber,
        description: 'Same class section scheduled twice simultaneously',
      ),
    ];

    return FadeTransition(
      opacity: _fade,
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? .4 : .12),
                blurRadius: 30,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: bd,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Scrollable content
              Expanded(
                child: ListView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    // ── Hero status bar ────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: allGood
                            ? const LinearGradient(
                                colors: [Color(0xFF059669), Color(0xFF0D9488)])
                            : const LinearGradient(
                                colors: [Color(0xFFDC2626), Color(0xFFB91C1C)]),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: (allGood ? AppTheme.success : AppTheme.error)
                                .withValues(alpha: .3),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .2),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              allGood
                                  ? Icons.check_circle_rounded
                                  : Icons.warning_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  allGood
                                      ? 'Perfect Schedule! 🎉'
                                      : '${result.totalClashes} Clash${result.totalClashes > 1 ? 'es' : ''} Remaining',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  allGood
                                      ? 'No clashes found after ${result.generationsRun} generations.'
                                      : 'After ${result.generationsRun} generations. Try increasing GA generations in Settings.',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12,
                                    color: Colors.white.withValues(alpha: .85),
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ── Summary stats row ──────────────────────────────────
                    Row(
                      children: [
                        _MiniStat(
                          label: 'Generations',
                          value: result.generationsRun.toString(),
                          icon: Icons.loop_rounded,
                          color: AppTheme.accentCyan,
                          isDark: isDark,
                        ),
                        const SizedBox(width: 10),
                        _MiniStat(
                          label: 'Hard Clashes',
                          value: result.totalClashes.toString(),
                          icon: Icons.cancel_rounded,
                          color: result.totalClashes == 0
                              ? AppTheme.success
                              : AppTheme.error,
                          isDark: isDark,
                        ),
                        const SizedBox(width: 10),
                        _MiniStat(
                          label: 'Soft Penalties',
                          value: (result.breakdown['total_soft'] ?? 0).toString(),
                          icon: Icons.tune_rounded,
                          color: AppTheme.accentAmber,
                          isDark: isDark,
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // ── Breakdown section header ────────────────────────────
                    Row(
                      children: [
                        Container(
                          width: 4, height: 16,
                          decoration: BoxDecoration(
                            color: AppTheme.accentViolet,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Clash Breakdown',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: tp,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // ── Category cards ─────────────────────────────────────
                    ...categories.map((cat) {
                      final count = result.breakdown[cat.key] ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ClashCategoryCard(
                          cat: cat,
                          count: count,
                          isDark: isDark,
                          tp: tp,
                          ts: ts,
                        ),
                      );
                    }),

                    // ── Pinned-vs-Pinned conflicts ─────────────────────────
                    // Only shown when manually-fixed assignments clash with
                    // each other. GA/CSP cannot resolve these — the user must
                    // unpin at least one of each pair.
                    if (result.pinnedClashes.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Container(
                            width: 4, height: 16,
                            decoration: BoxDecoration(
                              color: AppTheme.error,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Pinned Conflicts (Manual Action Required)',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.error,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withValues(alpha: isDark ? .10 : .06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AppTheme.error.withValues(alpha: .35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.lock_person_rounded,
                                  size: 14, color: AppTheme.error),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'These clashes are between two MANUALLY PINNED '
                                  'assignments. No algorithm can fix them automatically. '
                                  'Unpin (set to auto) at least one assignment from each '
                                  'pair below, then re-run.',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11,
                                    color: AppTheme.error,
                                    height: 1.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 10),
                            ...result.pinnedClashes.map((msg) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Icon(Icons.cancel_rounded,
                                        size: 13, color: AppTheme.error),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      msg,
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        color: ts,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // ── Message from GA ────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isDark ? AppTheme.bgCard : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: bd),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 16, color: AppTheme.accentCyan),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              result.message,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12,
                                color: ts,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── Action buttons ─────────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              height: 46,
                              decoration: BoxDecoration(
                                color: isDark ? AppTheme.bgCard : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: bd),
                              ),
                              child: Center(
                                child: Text(
                                  'Close',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: ts,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (widget.onViewSchedule != null) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: GestureDetector(
                              onTap: () {
                                Navigator.pop(context);
                                widget.onViewSchedule?.call();
                              },
                              child: Container(
                                height: 46,
                                decoration: BoxDecoration(
                                  gradient: AppTheme.heroGradient,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppTheme.accentCyan.withValues(alpha: .3),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.grid_view_rounded,
                                          size: 16, color: Colors.white),
                                      const SizedBox(width: 8),
                                      Text(
                                        'View Schedule',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data classes & sub-widgets
// ─────────────────────────────────────────────────────────────────────────────
class _ClashCategory {
  final String key;
  final String label;
  final IconData icon;
  final Color color;
  final String description;
  const _ClashCategory({
    required this.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.description,
  });
}

class _ClashCategoryCard extends StatelessWidget {
  final _ClashCategory cat;
  final int count;
  final bool isDark;
  final Color tp, ts;
  const _ClashCategoryCard({
    required this.cat,
    required this.count,
    required this.isDark,
    required this.tp,
    required this.ts,
  });

  @override
  Widget build(BuildContext context) {
    final color = count == 0 ? AppTheme.success : cat.color;
    final bg = isDark ? AppTheme.bgCard : Colors.white;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: count.toDouble()),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      builder: (_, v, __) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: count == 0 ? .3 : .45)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: .06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(cat.icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cat.label,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: tp,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    cat.description,
                    style: GoogleFonts.plusJakartaSans(fontSize: 10, color: ts),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  v.toInt().toString(),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: color,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  count == 0 ? 'None ✓' : 'clash${count > 1 ? 'es' : ''}',
                  style: GoogleFonts.plusJakartaSans(fontSize: 10, color: ts),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  final bool isDark;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppTheme.bgCard : Colors.white;
    final ts = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;

    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 6),
            Text(
              value,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
            Text(
              label,
              style: GoogleFonts.plusJakartaSans(fontSize: 10, color: ts),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
