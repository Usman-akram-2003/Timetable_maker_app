import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../../models/teacher.dart';
import '../../app_theme.dart';
import '../../utils/responsive.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Workload Screen — teacher-by-teacher hour analytics
// ─────────────────────────────────────────────────────────────────────────────

enum _SortMode { name, hoursAsc, hoursDesc, overload }

class WorkloadScreen extends StatefulWidget {
  const WorkloadScreen({super.key});
  @override
  State<WorkloadScreen> createState() => _WorkloadScreenState();
}

class _WorkloadScreenState extends State<WorkloadScreen> {
  _SortMode _sort = _SortMode.overload;
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
          // Build workload data per teacher
          final workloads = _buildWorkloads(dataVm, settingsVm.workingDays);

          // Filter by dept
          final depts = dataVm.departments.toSet().toList()..sort();
          var filtered = _deptFilter == null
              ? workloads
              : workloads.where((w) => w.teacher.department == _deptFilter).toList();

          // Filter by search
          if (_search.isNotEmpty) {
            final q = _search.toLowerCase();
            filtered = filtered.where((w) =>
                w.teacher.name.toLowerCase().contains(q) ||
                w.teacher.department.toLowerCase().contains(q)).toList();
          }

          // Sort
          filtered = List.from(filtered);
          switch (_sort) {
            case _SortMode.name:
              filtered.sort((a, b) => a.teacher.name.compareTo(b.teacher.name));
            case _SortMode.hoursAsc:
              filtered.sort((a, b) => a.assignedHours.compareTo(b.assignedHours));
            case _SortMode.hoursDesc:
              filtered.sort((a, b) => b.assignedHours.compareTo(a.assignedHours));
            case _SortMode.overload:
              filtered.sort((a, b) {
                final aStatus = a.status.index;
                final bStatus = b.status.index;
                return bStatus.compareTo(aStatus);
              });
          }

          // Summary stats
          final totalTeachers = workloads.length;
          final overloaded = workloads.where((w) => w.status == _WorkloadStatus.overloaded).length;
          final underAssigned = workloads.where((w) => w.status == _WorkloadStatus.under).length;
          final balanced = workloads.where((w) => w.status == _WorkloadStatus.balanced).length;
          final totalHours = workloads.fold<double>(0, (s, w) => s + w.assignedHours);

          final showList = dataVm.teachers.isNotEmpty && filtered.isNotEmpty;

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: CustomScrollView(slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(hp, 56, hp, showList ? 0 : 40),
                  sliver: SliverToBoxAdapter(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // ── Header ─────────────────────────────────────────────
                  Row(
                    children: [
                      Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF06B6D4), Color(0xFF0891B2)]),
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [BoxShadow(
                              color: AppTheme.accentCyan.withValues(alpha: .4),
                              blurRadius: 18, offset: const Offset(0, 5))],
                        ),
                        child: const Icon(Icons.bar_chart_rounded,
                            color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Workload Analytics',
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 24, fontWeight: FontWeight.w800,
                                color: tp, letterSpacing: -0.5)),
                        Text('Teacher assignment hours & distribution',
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 13, color: ts)),
                      ]),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── Summary stat row ────────────────────────────────────
                  _SummaryRow(
                    totalTeachers: totalTeachers,
                    totalHours: totalHours,
                    overloaded: overloaded,
                    underAssigned: underAssigned,
                    balanced: balanced,
                    isDark: isDark,
                  ),

                  const SizedBox(height: 20),

                  // ── Search + Sort + Dept filter ─────────────────────────
                  _ControlBar(
                    searchCtrl: _searchCtrl,
                    sort: _sort,
                    deptFilter: _deptFilter,
                    depts: depts,
                    isDark: isDark,
                    tp: tp,
                    ts: ts,
                    bd: bd,
                    onSearch: (v) => setState(() => _search = v),
                    onSort: (s) => setState(() => _sort = s),
                    onDept: (d) => setState(() => _deptFilter = d),
                  ),

                  const SizedBox(height: 16),

                  // ── Empty state ─────────────────────────────────────────
                  if (dataVm.teachers.isEmpty)
                    _emptyState(tp, ts, 'No teachers added yet',
                        'Add teachers in Manage Data first.')
                  else if (filtered.isEmpty)
                    _emptyState(tp, ts, 'No results',
                        'Try adjusting your search or filter.')
                  else
                    Text(
                      '${filtered.length} teacher${filtered.length > 1 ? 's' : ''}',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 12, color: ts, fontWeight: FontWeight.w600),
                    ),
                  if (showList) const SizedBox(height: 10),
                    ]),
                  ),
                ),
                // Lazily built — only the teacher cards actually on screen get
                // built, instead of the whole (unbounded) filtered list every
                // time the search box or sort/dept filter changes.
                if (showList)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(hp, 0, hp, 40),
                    sliver: SliverList.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _TeacherWorkloadCard(
                          workload: filtered[i],
                          isDark: isDark,
                          tp: tp,
                          ts: ts,
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _emptyState(Color tp, Color ts, String title, String sub) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        const Icon(Icons.bar_chart_outlined, size: 48, color: AppTheme.textMuted),
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

  // "HH:mm" → minutes since midnight.
  static int _parseMin(String t) {
    final p = t.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  List<_TeacherWorkload> _buildWorkloads(DataEntryViewModel vm, int workingDays) {
    // Real clock-hours for one occurrence of a period, from its Data-tab
    // Time Slot record — Intermediate periods (~40min) and Bachelor's
    // periods (~1hr) are NOT equivalent, so a raw slot count can't stand
    // in for "hours" across levels.
    double slotHours(String timeSlotId) {
      final ts = vm.timeSlots.where((t) => t.id == timeSlotId).firstOrNull;
      if (ts == null) return 1.0;
      final mins = _parseMin(ts.endTime) - _parseMin(ts.startTime);
      return mins > 0 ? mins / 60.0 : 1.0;
    }

    final result = <_TeacherWorkload>[];
    for (final teacher in vm.teachers) {
      final assignments = vm.assignments
          .where((a) => a.teacher.id == teacher.id)
          .toList();

      final items = <_WorkloadItem>[];
      double assignedHours = 0;
      double expectedHours = 0;

      for (final a in assignments) {
        final hours = a.occupiedSlots.length * slotHours(a.timeSlotId);
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

      // Elective load — electives only exist at Intermediate level, and use
      // an Intermediate time slot, so slotHours() already gives the right
      // (shorter) duration for them without any special-casing here. Unlike
      // a regular Assignment, ElectiveGroup has no day-of-week (or occurrence
      // count) field at all, so how many times/week an entry actually meets
      // has to come from its course's credit hours — same convention as
      // regular assignments, where duration/week is set to match creditHours
      // (a 6-credit-hour subject meets daily, a 2-credit-hour one meets twice).
      for (final eg in vm.electiveGroups) {
        final perPeriod = slotHours(eg.timeSlotId);
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

  const _TeacherWorkload({
    required this.teacher,
    required this.items,
    required this.assignedHours,
    required this.expectedHours,
  });

  _WorkloadStatus get status {
    if (items.isEmpty) return _WorkloadStatus.idle;
    // Small tolerance: these are now real clock-hours built from repeating
    // decimals (e.g. 40min = 0.6666...h), so exact equality would almost
    // never trigger "balanced" even when the schedule matches the target.
    const epsilon = 0.05;
    final diff = assignedHours - expectedHours;
    if (diff < -epsilon) return _WorkloadStatus.under;
    if (diff > epsilon) return _WorkloadStatus.overloaded;
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary row
// ─────────────────────────────────────────────────────────────────────────────
class _SummaryRow extends StatelessWidget {
  final int totalTeachers, overloaded, underAssigned, balanced;
  final double totalHours;
  final bool isDark;
  const _SummaryRow({
    required this.totalTeachers,
    required this.totalHours,
    required this.overloaded,
    required this.underAssigned,
    required this.balanced,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppTheme.bgCard : Colors.white;
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final ts = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final tp = isDark ? AppTheme.textPrimary : AppTheme.lightText;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bd),
      ),
      child: Row(
        children: [
          _SumCell('$totalTeachers', 'Total Teachers', AppTheme.accentCyan, tp, ts),
          _div(bd),
          _SumCell(_fmtHours(totalHours), 'Total Hours', AppTheme.accentBlue, tp, ts),
          _div(bd),
          _SumCell('$balanced', 'Balanced', AppTheme.success, tp, ts),
          _div(bd),
          _SumCell('$underAssigned', 'Under', AppTheme.accentAmber, tp, ts),
          _div(bd),
          _SumCell('$overloaded', 'Overloaded', AppTheme.error, tp, ts),

        ],
      ),
    );
  }

  Widget _div(Color bd) => Container(
        width: 1, height: 32, color: bd,
        margin: const EdgeInsets.symmetric(horizontal: 10));
}

class _SumCell extends StatelessWidget {
  final String value, label;
  final Color color, tp, ts;
  const _SumCell(this.value, this.label, this.color, this.tp, this.ts);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 20, fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: GoogleFonts.plusJakartaSans(fontSize: 10, color: ts),
                textAlign: TextAlign.center),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Control bar — search, sort, dept filter
// ─────────────────────────────────────────────────────────────────────────────
class _ControlBar extends StatelessWidget {
  final TextEditingController searchCtrl;
  final _SortMode sort;
  final String? deptFilter;
  final List<String> depts;
  final bool isDark;
  final Color tp, ts, bd;
  final ValueChanged<String> onSearch;
  final ValueChanged<_SortMode> onSort;
  final ValueChanged<String?> onDept;

  const _ControlBar({
    required this.searchCtrl,
    required this.sort,
    required this.deptFilter,
    required this.depts,
    required this.isDark,
    required this.tp,
    required this.ts,
    required this.bd,
    required this.onSearch,
    required this.onSort,
    required this.onDept,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppTheme.bgCard : Colors.white;
    return Column(
      children: [
        // Search bar
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: bd),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(Icons.search_rounded, size: 18, color: ts),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: searchCtrl,
                  onChanged: onSearch,
                  style: GoogleFonts.plusJakartaSans(fontSize: 13, color: tp),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Search teacher or department…',
                    hintStyle: GoogleFonts.plusJakartaSans(
                        fontSize: 13, color: ts),
                    isDense: true,
                  ),
                ),
              ),
              if (searchCtrl.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    searchCtrl.clear();
                    onSearch('');
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Icon(Icons.close_rounded, size: 16, color: ts),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Sort + dept row
        Row(
          children: [
            // Sort dropdown
            Expanded(
              child: _SmallDropdown<_SortMode>(
                value: sort,
                isDark: isDark,
                tp: tp,
                ts: ts,
                bd: bd,
                icon: Icons.sort_rounded,
                items: const [
                  DropdownMenuItem(
                      value: _SortMode.overload, child: Text('Sort: Status')),
                  DropdownMenuItem(
                      value: _SortMode.name, child: Text('Sort: A–Z')),
                  DropdownMenuItem(
                      value: _SortMode.hoursAsc, child: Text('Sort: Hours ↑')),
                  DropdownMenuItem(
                      value: _SortMode.hoursDesc, child: Text('Sort: Hours ↓')),
                ],
                onChanged: (v) { if (v != null) onSort(v); },
              ),
            ),
            const SizedBox(width: 10),
            // Dept filter
            if (depts.isNotEmpty)
              Expanded(
                child: _SmallDropdown<String?>(
                  value: deptFilter,
                  isDark: isDark,
                  tp: tp,
                  ts: ts,
                  bd: bd,
                  icon: Icons.business_rounded,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Departments')),
                    ...depts.map((d) => DropdownMenuItem(value: d, child: Text(d))),
                  ],
                  onChanged: onDept,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SmallDropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final bool isDark;
  final Color tp, ts, bd;
  final IconData icon;

  const _SmallDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.isDark,
    required this.tp,
    required this.ts,
    required this.bd,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppTheme.bgCard : Colors.white;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: bd),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          icon: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: ts),
          dropdownColor: bg,
          isExpanded: true,
          style: GoogleFonts.plusJakartaSans(fontSize: 12, color: tp),
          onChanged: onChanged,
          items: items,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Teacher Workload Card
// ─────────────────────────────────────────────────────────────────────────────
class _TeacherWorkloadCard extends StatefulWidget {
  final _TeacherWorkload workload;
  final bool isDark;
  final Color tp, ts;
  const _TeacherWorkloadCard({
    required this.workload,
    required this.isDark,
    required this.tp,
    required this.ts,
  });

  @override
  State<_TeacherWorkloadCard> createState() => _TeacherWorkloadCardState();
}

class _TeacherWorkloadCardState extends State<_TeacherWorkloadCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.workload;
    final isDark = widget.isDark;
    final bg = isDark ? AppTheme.bgCard : Colors.white;
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final statusColor = w.statusColor;
    final fillRatio = w.expectedHours == 0
        ? 0.0
        : (w.assignedHours / w.expectedHours).clamp(0.0, 1.5);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: .35)),
        boxShadow: [
          BoxShadow(
              color: statusColor.withValues(alpha: .06),
              blurRadius: 8,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          // ── Main row ────────────────────────────────────────────────────
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      // Avatar
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: .14),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            w.teacher.name.isNotEmpty
                                ? w.teacher.name[0].toUpperCase()
                                : '?',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w.teacher.name,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: widget.tp,
                              ),
                            ),
                            if (w.teacher.department.isNotEmpty)
                              Text(
                                w.teacher.department,
                                style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11, color: widget.ts),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Hours badge
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${_fmtHours(w.assignedHours)} / ${_fmtHours(w.expectedHours)}h',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              w.statusLabel,
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: statusColor),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: widget.ts,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Progress bar
                  LayoutBuilder(builder: (_, box) {
                    return Stack(
                      children: [
                        Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: .14),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: fillRatio.clamp(0.0, 1.0)),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOut,
                          builder: (_, v, __) => Container(
                            height: 6,
                            width: box.maxWidth * v,
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(3),
                              boxShadow: [
                                BoxShadow(
                                    color: statusColor.withValues(alpha: .4),
                                    blurRadius: 4)
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ],
              ),
            ),
          ),

          // ── Expanded detail ──────────────────────────────────────────────
          if (_expanded) ...[
            Divider(color: bd, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: w.items.isEmpty
                  ? Text(
                      'No assignments yet for this teacher.',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 12, color: widget.ts),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Course Breakdown',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: widget.ts,
                            letterSpacing: .3,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...w.items.map((it) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: statusColor),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      it.title,
                                      style: GoogleFonts.plusJakartaSans(
                                          fontSize: 12, color: widget.tp),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    it.classLabel,
                                    style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11, color: widget.ts),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_fmtHours(it.hours)}h  •  ${it.scheduleLabel}',
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: statusColor,
                                    ),
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
