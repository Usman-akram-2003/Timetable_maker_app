import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../../models/teacher.dart';
import '../../models/education_level.dart';
import '../../app_theme.dart';
import '../../utils/responsive.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Workload Screen — hours delta against target, per teacher
// ─────────────────────────────────────────────────────────────────────────────

enum _SortMode { delta, name, hoursAsc, hoursDesc }

const _accent = Color(0xFFF97316);
const _accent2 = Color(0xFFEA580C);

class WorkloadScreen extends StatefulWidget {
  const WorkloadScreen({super.key});
  @override
  State<WorkloadScreen> createState() => _WorkloadScreenState();
}

class _WorkloadScreenState extends State<WorkloadScreen> {
  _SortMode _sort = _SortMode.delta;
  String? _deptFilter;
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tp = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final ts = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final hp = context.hPad;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Consumer2<DataEntryViewModel, SettingsViewModel>(
        builder: (ctx, dataVm, settingsVm, _) {
          final workloads = _buildWorkloads(
              dataVm, settingsVm.workingDays, settingsVm.workloadTolerance);

          final depts = dataVm.departments.toSet().toList()..sort();
          var filtered = _deptFilter == null
              ? workloads
              : workloads.where((w) => w.teacher.department == _deptFilter).toList();

          if (_search.isNotEmpty) {
            final q = _search.toLowerCase();
            filtered = filtered.where((w) =>
                w.teacher.name.toLowerCase().contains(q) ||
                w.teacher.department.toLowerCase().contains(q)).toList();
          }

          filtered = List.from(filtered);
          switch (_sort) {
            case _SortMode.delta:
              filtered.sort((a, b) {
                final aIdle = a.status == _WorkloadStatus.idle;
                final bIdle = b.status == _WorkloadStatus.idle;
                if (aIdle != bIdle) return aIdle ? 1 : -1;
                return b.delta.compareTo(a.delta);
              });
            case _SortMode.name:
              filtered.sort((a, b) => a.teacher.name.compareTo(b.teacher.name));
            case _SortMode.hoursAsc:
              filtered.sort((a, b) => a.assignedHours.compareTo(b.assignedHours));
            case _SortMode.hoursDesc:
              filtered.sort((a, b) => b.assignedHours.compareTo(a.assignedHours));
          }

          final totalTeachers = workloads.length;
          final totalHours = workloads.fold<double>(0, (s, w) => s + w.assignedHours);
          final balanced = workloads.where((w) => w.status == _WorkloadStatus.balanced).length;
          final under = workloads.where((w) => w.status == _WorkloadStatus.under).length;
          final overloaded = workloads.where((w) => w.status == _WorkloadStatus.overloaded).length;
          final idle = workloads.where((w) => w.status == _WorkloadStatus.idle).length;
          final needsAttention = under + overloaded;

          final plottable = filtered.where((w) => w.status != _WorkloadStatus.idle);
          final maxAbsDelta = plottable.isEmpty
              ? 1.0
              : plottable.map((w) => w.delta.abs()).reduce((a, b) => a > b ? a : b).clamp(0.15, double.infinity);

          final showList = dataVm.teachers.isNotEmpty && filtered.isNotEmpty;

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: ListView(
                padding: EdgeInsets.fromLTRB(hp, 56, hp, 40),
                children: [

                  // ── Header ─────────────────────────────────────────────
                  Row(children: [
                    Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [_accent, _accent2]),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [BoxShadow(
                            color: _accent.withValues(alpha: .4),
                            blurRadius: 18, offset: const Offset(0, 5))],
                      ),
                      child: const Icon(LucideIcons.activity, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Workload Analytics',
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 24, fontWeight: FontWeight.w800,
                              color: tp, letterSpacing: -0.5)),
                      Text('Hours assigned vs. target, across your teaching staff',
                          style: GoogleFonts.plusJakartaSans(fontSize: 13, color: ts)),
                    ]),
                  ]),

                  const SizedBox(height: 24),

                  if (dataVm.teachers.isNotEmpty) ...[
                    // ── KPI row ───────────────────────────────────────────
                    Row(children: [
                      _KpiTile(icon: LucideIcons.users, label: 'Teachers',
                          value: '$totalTeachers', isDark: isDark, tp: tp, ts: ts),
                      const SizedBox(width: 14),
                      _KpiTile(icon: LucideIcons.clock, label: 'Total Load',
                          value: '${_fmtHours(totalHours)}h', isDark: isDark, tp: tp, ts: ts),
                      const SizedBox(width: 14),
                      _KpiTile(icon: LucideIcons.checkCircle2, label: 'Balanced',
                          value: '$balanced',
                          note: idle > 0 ? '$idle no assignments' : null,
                          isDark: isDark, tp: tp, ts: ts),
                      const SizedBox(width: 14),
                      _KpiTile(icon: LucideIcons.alertTriangle, label: 'Needs attention',
                          value: '$needsAttention',
                          note: '$overloaded overloaded · $under under',
                          hot: needsAttention > 0,
                          isDark: isDark, tp: tp, ts: ts),
                    ]),

                    const SizedBox(height: 18),

                    // ── Status distribution ────────────────────────────────
                    _panel(isDark, bd, child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('STATUS DISTRIBUTION', style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5, fontWeight: FontWeight.w700, color: ts, letterSpacing: .3)),
                        const SizedBox(height: 12),
                        _StatusStack(balanced: balanced, under: under, overloaded: overloaded, idle: idle),
                        const SizedBox(height: 12),
                        Wrap(spacing: 20, runSpacing: 8, children: [
                          _legendItem(AppTheme.success, 'Balanced', balanced, tp, ts),
                          _legendItem(AppTheme.accentAmber, 'Under-assigned', under, tp, ts),
                          _legendItem(AppTheme.error, 'Overloaded', overloaded, tp, ts),
                          _legendItem(AppTheme.textMuted, 'No assignments', idle, tp, ts),
                        ]),
                      ],
                    )),

                    const SizedBox(height: 18),

                    // ── Toolbar ─────────────────────────────────────────────
                    Row(children: [
                      Expanded(child: Container(
                        height: 42,
                        decoration: BoxDecoration(
                          color: isDark ? AppTheme.bgCard : Colors.white,
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(color: bd),
                        ),
                        child: Row(children: [
                          const SizedBox(width: 12),
                          Icon(LucideIcons.search, size: 17, color: ts),
                          const SizedBox(width: 8),
                          Expanded(child: TextField(
                            controller: _searchCtrl,
                            onChanged: (v) => setState(() => _search = v),
                            style: GoogleFonts.plusJakartaSans(fontSize: 13, color: tp),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: 'Search teacher or department…',
                              hintStyle: GoogleFonts.plusJakartaSans(fontSize: 13, color: ts),
                              isDense: true,
                            ),
                          )),
                          if (_searchCtrl.text.isNotEmpty)
                            GestureDetector(
                              onTap: () { _searchCtrl.clear(); setState(() => _search = ''); },
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Icon(LucideIcons.x, size: 15, color: ts),
                              ),
                            ),
                        ]),
                      )),
                      const SizedBox(width: 10),
                      _SortPill(sort: _sort, isDark: isDark, tp: tp, ts: ts, bd: bd,
                          onChanged: (s) => setState(() => _sort = s)),
                      if (depts.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        _DeptDropdown(depts: depts, value: _deptFilter,
                            isDark: isDark, tp: tp, ts: ts, bd: bd,
                            onChanged: (v) => setState(() => _deptFilter = v)),
                      ],
                    ]),

                    const SizedBox(height: 18),
                  ],

                  // ── Empty states ─────────────────────────────────────────
                  if (dataVm.teachers.isEmpty)
                    _emptyState(tp, ts, 'No teachers added yet',
                        'Add teachers in Manage Data first.')
                  else if (filtered.isEmpty)
                    _emptyState(tp, ts, 'No results',
                        'Try adjusting your search or filter.')
                  else
                    _panel(isDark, bd, pad: const EdgeInsets.fromLTRB(18, 14, 18, 4), child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('← UNDER-ASSIGNED', style: GoogleFonts.plusJakartaSans(
                              fontSize: 10, fontWeight: FontWeight.w700, color: ts, letterSpacing: .3)),
                          Text('ON TARGET', style: GoogleFonts.plusJakartaSans(
                              fontSize: 10, fontWeight: FontWeight.w700, color: ts, letterSpacing: .3)),
                          Text('OVERLOADED →', style: GoogleFonts.plusJakartaSans(
                              fontSize: 10, fontWeight: FontWeight.w700, color: ts, letterSpacing: .3)),
                        ]),
                        const SizedBox(height: 4),
                        for (final w in filtered)
                          _DivergingRow(workload: w, maxAbsDelta: maxAbsDelta,
                              isDark: isDark, tp: tp, ts: ts, bd: bd),
                      ],
                    )),
                  if (showList) const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Widget _panel(bool isDark, Color bd, {required Widget child, EdgeInsets? pad}) => Container(
    padding: pad ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: isDark ? AppTheme.bgCard : Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: bd),
    ),
    child: child,
  );

  static Widget _legendItem(Color color, String label, int count, Color tp, Color ts) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts)),
      const SizedBox(width: 5),
      Text('$count', style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w800, color: tp)),
    ],
  );

  Widget _emptyState(Color tp, Color ts, String title, String sub) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        const Icon(LucideIcons.barChart3, size: 44, color: AppTheme.textMuted),
        const SizedBox(height: 12),
        Text(title,
            style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, fontSize: 16, color: tp)),
        const SizedBox(height: 4),
        Text(sub,
            style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts),
            textAlign: TextAlign.center),
      ],
    ),
  );

  List<_TeacherWorkload> _buildWorkloads(DataEntryViewModel vm, int workingDays, double tolerance) {
    // Institutional workload weighting, not real clock-time: the school
    // counts 2 Bachelor periods as the same load as 3 Intermediate periods,
    // so a Bachelor period is worth 1.5 workload-hours against Intermediate's
    // 1.0 baseline. Course credit-hour targets are left exactly as entered —
    // only the *assigned* side is weighted this way.
    double levelWeight(EducationLevel level) =>
        level == EducationLevel.bachelors ? 1.5 : 1.0;

    final result = <_TeacherWorkload>[];
    for (final teacher in vm.teachers) {
      final assignments = vm.assignments
          .where((a) => a.teacher.id == teacher.id)
          .toList();

      final items = <_WorkloadItem>[];
      double assignedHours = 0;
      double expectedHours = 0;

      for (final a in assignments) {
        final hours = a.occupiedSlots.length * levelWeight(a.classModel.level);
        assignedHours += hours;
        // Credit hours is the curriculum's real-hour target for this course,
        // independent of level — do NOT scale it by slot duration. Scaling
        // both sides would hide exactly the shortfall this fix is meant to
        // surface: an Intermediate course delivered in short 40min periods
        // genuinely provides fewer real hours than its credit-hour target.
        expectedHours += a.course.creditHours;
        items.add(_WorkloadItem(
          title: '${a.course.name} (${a.course.code})',
          classLabel: a.classModel.shortCode,
          scheduleLabel: a.daysLabel,
          hours: hours,
        ));
      }

      // Elective load — electives only exist at Intermediate level, so the
      // Intermediate workload weight applies to every entry here. Unlike a
      // regular Assignment, ElectiveGroup has no day-of-week (or occurrence
      // count) field at all, so how many times/week an entry actually meets
      // has to come from its course's credit hours — same convention as
      // regular assignments, where duration/week is set to match creditHours
      // (a 6-credit-hour subject meets daily, a 2-credit-hour one meets twice).
      for (final eg in vm.electiveGroups) {
        final perPeriod = levelWeight(EducationLevel.intermediate);
        final classLabel = eg.classIds
            .map((id) => vm.classes.where((c) => c.id == id).firstOrNull?.shortCode)
            .whereType<String>()
            .join('+');
        for (final entry in eg.entries.where((e) => e.teacherId == teacher.id)) {
          final course = vm.courses.where((c) => c.id == entry.courseId).firstOrNull;
          final perWeekCount = course?.creditHours ?? workingDays;
          final perWeek = perPeriod * perWeekCount;
          final daysLabel = perWeekCount >= workingDays
              ? (workingDays >= 6 ? 'Mon–Sat' : 'Mon–Fri')
              : '${perWeekCount}x/week';
          assignedHours += perWeek;
          expectedHours += course?.creditHours ?? 0;
          items.add(_WorkloadItem(
            title: course != null ? '${entry.courseName} (${course.code})' : entry.courseName,
            classLabel: classLabel.isEmpty ? 'Elective' : classLabel,
            scheduleLabel: 'Elective • $daysLabel',
            hours: perWeek,
          ));
        }
      }

      result.add(_TeacherWorkload(
        teacher: teacher,
        items: items,
        assignedHours: assignedHours,
        expectedHours: expectedHours,
        tolerance: tolerance,
      ));
    }
    return result;
  }
}

// Trims to at most 1 decimal, dropping a trailing ".0".
String _fmtHours(double h) {
  final rounded = (h * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
}

// Signed variant for delta labels — always shows +/-.
String _fmtDelta(double h) {
  final sign = h > 0 ? '+' : (h < 0 ? '−' : '');
  return '$sign${_fmtHours(h.abs())}h';
}

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────
enum _WorkloadStatus { idle, under, balanced, overloaded }

// One line item in a teacher's breakdown — either a regular assignment or
// an elective-group entry (electives don't have an Assignment record).
class _WorkloadItem {
  final String title;
  final String classLabel;
  final String scheduleLabel;
  final double hours;
  const _WorkloadItem({
    required this.title,
    required this.classLabel,
    required this.scheduleLabel,
    required this.hours,
  });
}

class _TeacherWorkload {
  final Teacher teacher;
  final List<_WorkloadItem> items;
  final double assignedHours;
  final double expectedHours;
  // Configurable in Settings → Workload Thresholds; how close assigned must
  // be to expected hours to count as "Balanced" rather than under/overloaded.
  final double tolerance;

  const _TeacherWorkload({
    required this.teacher,
    required this.items,
    required this.assignedHours,
    required this.expectedHours,
    required this.tolerance,
  });

  double get delta => assignedHours - expectedHours;

  _WorkloadStatus get status {
    if (items.isEmpty) return _WorkloadStatus.idle;
    final diff = delta;
    if (diff < -tolerance) return _WorkloadStatus.under;
    if (diff > tolerance) return _WorkloadStatus.overloaded;
    return _WorkloadStatus.balanced;
  }

  Color get statusColor {
    switch (status) {
      case _WorkloadStatus.idle:       return AppTheme.textMuted;
      case _WorkloadStatus.under:      return AppTheme.accentAmber;
      case _WorkloadStatus.balanced:   return AppTheme.success;
      case _WorkloadStatus.overloaded: return AppTheme.error;
    }
  }

  String get statusLabel {
    switch (status) {
      case _WorkloadStatus.idle:       return 'No Assignments';
      case _WorkloadStatus.under:      return 'Under-assigned';
      case _WorkloadStatus.balanced:   return 'Balanced';
      case _WorkloadStatus.overloaded: return 'Overloaded';
    }
  }

  IconData get statusIcon {
    switch (status) {
      case _WorkloadStatus.idle:       return LucideIcons.circleSlash;
      case _WorkloadStatus.under:      return LucideIcons.alertCircle;
      case _WorkloadStatus.balanced:   return LucideIcons.checkCircle2;
      case _WorkloadStatus.overloaded: return LucideIcons.alertTriangle;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KPI tile
// ─────────────────────────────────────────────────────────────────────────────
class _KpiTile extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final String? note;
  final bool hot;
  final bool isDark;
  final Color tp, ts;
  const _KpiTile({
    required this.icon, required this.label, required this.value,
    this.note, this.hot = false, required this.isDark, required this.tp, required this.ts,
  });

  @override
  Widget build(BuildContext context) {
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final valueColor = hot ? AppTheme.error : tp;
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: hot
            ? AppTheme.error.withValues(alpha: .10)
            : (isDark ? AppTheme.bgCard : Colors.white),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: hot ? AppTheme.error.withValues(alpha: .35) : bd),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 24, height: 24,
              decoration: BoxDecoration(
                  color: (hot ? AppTheme.error : ts).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(7)),
              child: Icon(icon, size: 13, color: hot ? AppTheme.error : ts)),
          const SizedBox(width: 8),
          Expanded(child: Text(label,
              style: GoogleFonts.plusJakartaSans(fontSize: 11.5, fontWeight: FontWeight.w600, color: ts),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 10),
        Text(value, style: GoogleFonts.plusJakartaSans(
            fontSize: 22, fontWeight: FontWeight.w800, color: valueColor, letterSpacing: -.3)),
        if (note != null) ...[
          const SizedBox(height: 2),
          Text(note!, style: GoogleFonts.plusJakartaSans(fontSize: 10.5, color: ts),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ]),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status distribution stacked bar
// ─────────────────────────────────────────────────────────────────────────────
class _StatusStack extends StatelessWidget {
  final int balanced, under, overloaded, idle;
  const _StatusStack({required this.balanced, required this.under, required this.overloaded, required this.idle});

  @override
  Widget build(BuildContext context) {
    final segs = <(int, Color)>[
      (balanced, AppTheme.success),
      (under, AppTheme.accentAmber),
      (overloaded, AppTheme.error),
      (idle, AppTheme.textMuted),
    ].where((s) => s.$1 > 0).toList();

    if (segs.isEmpty) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(children: [
        for (int i = 0; i < segs.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Expanded(flex: segs[i].$1, child: Container(height: 18, color: segs[i].$2)),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sort pill
// ─────────────────────────────────────────────────────────────────────────────
class _SortPill extends StatelessWidget {
  final _SortMode sort;
  final bool isDark;
  final Color tp, ts, bd;
  final ValueChanged<_SortMode> onChanged;
  const _SortPill({required this.sort, required this.isDark, required this.tp,
      required this.ts, required this.bd, required this.onChanged});

  static const _labels = {
    _SortMode.delta: 'Sort: Delta',
    _SortMode.name: 'Sort: A–Z',
    _SortMode.hoursAsc: 'Sort: Hours ↑',
    _SortMode.hoursDesc: 'Sort: Hours ↓',
  };

  @override
  Widget build(BuildContext context) => Container(
    height: 42,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: isDark ? AppTheme.bgCard : Colors.white,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: bd),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<_SortMode>(
        value: sort,
        icon: Icon(LucideIcons.chevronDown, size: 15, color: ts),
        dropdownColor: isDark ? AppTheme.bgCard : Colors.white,
        style: GoogleFonts.plusJakartaSans(fontSize: 12.5, fontWeight: FontWeight.w600, color: tp),
        items: _labels.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) { if (v != null) onChanged(v); },
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Department filter — type-to-search dropdown (quick jump, not a scroll wall)
// ─────────────────────────────────────────────────────────────────────────────
class _DeptDropdown extends StatelessWidget {
  final List<String> depts;
  final String? value;
  final bool isDark;
  final Color tp, ts, bd;
  final ValueChanged<String?> onChanged;
  const _DeptDropdown({required this.depts, required this.value, required this.isDark,
      required this.tp, required this.ts, required this.bd, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(11),
      borderSide: BorderSide(color: bd),
    );
    return DropdownMenu<String?>(
      key: ValueKey('deptFilter_${value ?? 'all'}'),
      width: 230,
      initialSelection: value,
      hintText: 'All departments',
      requestFocusOnTap: true,
      enableFilter: true,
      menuHeight: 340,
      leadingIcon: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Icon(LucideIcons.building2, size: 16, color: ts),
      ),
      textStyle: GoogleFonts.plusJakartaSans(fontSize: 12.5, fontWeight: FontWeight.w600, color: tp),
      trailingIcon: Icon(LucideIcons.chevronDown, size: 15, color: ts),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        constraints: const BoxConstraints(maxHeight: 42, minHeight: 42),
        hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12.5, color: ts),
        filled: true,
        fillColor: isDark ? AppTheme.bgCard : Colors.white,
        border: border,
        enabledBorder: border,
        focusedBorder: border,
      ),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(isDark ? AppTheme.bgCard : Colors.white),
        maximumSize: const WidgetStatePropertyAll(Size(320, 340)),
      ),
      dropdownMenuEntries: [
        const DropdownMenuEntry<String?>(value: null, label: 'All departments'),
        ...depts.map((d) => DropdownMenuEntry<String?>(value: d, label: d)),
      ],
      onSelected: onChanged,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Diverging bar row — assigned vs. expected, centered on a zero baseline
// ─────────────────────────────────────────────────────────────────────────────
class _DivergingRow extends StatefulWidget {
  final _TeacherWorkload workload;
  final double maxAbsDelta;
  final bool isDark;
  final Color tp, ts, bd;
  const _DivergingRow({
    required this.workload, required this.maxAbsDelta,
    required this.isDark, required this.tp, required this.ts, required this.bd,
  });

  @override
  State<_DivergingRow> createState() => _DivergingRowState();
}

class _DivergingRowState extends State<_DivergingRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.workload;
    final isIdle = w.status == _WorkloadStatus.idle;
    final isDeadZone = !isIdle && w.delta.abs() < 0.15;
    final frac = isIdle ? 0.0 : (w.delta.abs() / widget.maxAbsDelta).clamp(0.0, 1.0);

    return Column(children: [
      GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: widget.bd)),
          ),
          child: Row(children: [
            SizedBox(
              width: 180,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(w.teacher.name, style: GoogleFonts.plusJakartaSans(
                    fontSize: 13, fontWeight: FontWeight.w700, color: widget.tp),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (w.teacher.department.isNotEmpty)
                  Text(w.teacher.department, style: GoogleFonts.plusJakartaSans(
                      fontSize: 11, color: widget.ts),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: isIdle
                  ? Text('No assignments yet', style: GoogleFonts.plusJakartaSans(
                      fontSize: 12, color: widget.ts, fontStyle: FontStyle.italic))
                  : SizedBox(
                      height: 24,
                      child: Row(children: [
                        // left half — under-assigned bars anchor to the baseline
                        Expanded(child: Align(
                          alignment: Alignment.centerRight,
                          child: (!isDeadZone && w.delta < 0)
                              ? FractionallySizedBox(
                                  widthFactor: frac,
                                  alignment: Alignment.centerRight,
                                  child: Container(height: 20,
                                      decoration: BoxDecoration(
                                          color: w.statusColor,
                                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(4)))),
                                )
                              : const SizedBox(width: 1),
                        )),
                        Container(width: 1, height: 24, color: widget.ts.withValues(alpha: .3)),
                        // right half — overloaded bars, and the on-target marker
                        Expanded(child: Align(
                          alignment: Alignment.centerLeft,
                          child: isDeadZone
                              ? Container(width: 10, height: 10,
                                  decoration: BoxDecoration(color: w.statusColor, shape: BoxShape.circle,
                                      boxShadow: [BoxShadow(color: w.statusColor.withValues(alpha: .25), blurRadius: 0, spreadRadius: 4)]))
                              : (w.delta > 0
                                  ? FractionallySizedBox(
                                      widthFactor: frac,
                                      alignment: Alignment.centerLeft,
                                      child: Container(height: 20,
                                          decoration: BoxDecoration(
                                              color: w.statusColor,
                                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)))),
                                    )
                                  : const SizedBox(width: 1)),
                        )),
                      ]),
                    ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 78,
              child: Text(
                isIdle ? '' : (isDeadZone ? 'On target' : _fmtDelta(w.delta)),
                textAlign: TextAlign.right,
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5, fontWeight: FontWeight.w700, color: widget.ts),
              ),
            ),
            const SizedBox(width: 8),
            Icon(w.statusIcon, size: 15, color: w.statusColor),
            const SizedBox(width: 6),
            Icon(_expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 16, color: widget.ts),
          ]),
        ),
      ),
      if (_expanded)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(left: 4, right: 4, top: 8, bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: (widget.isDark ? Colors.white : Colors.black).withValues(alpha: .03),
            borderRadius: BorderRadius.circular(12),
          ),
          child: w.items.isEmpty
              ? Text('No assignments yet for this teacher.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: widget.ts))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('COURSE BREAKDOWN — ${_fmtHours(w.assignedHours)}h assigned / ${_fmtHours(w.expectedHours)}h target',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 10.5, fontWeight: FontWeight.w700, color: widget.ts, letterSpacing: .3)),
                  const SizedBox(height: 8),
                  ...w.items.map((it) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(children: [
                          Container(width: 6, height: 6,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: _accent)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(it.title,
                              style: GoogleFonts.plusJakartaSans(fontSize: 12, color: widget.tp),
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 8),
                          Text(it.classLabel, style: GoogleFonts.plusJakartaSans(fontSize: 11, color: widget.ts)),
                          const SizedBox(width: 8),
                          Text('${_fmtHours(it.hours)}h  •  ${it.scheduleLabel}',
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11, fontWeight: FontWeight.w600, color: _accent)),
                        ]),
                      )),
                ]),
        ),
    ]);
  }
}
