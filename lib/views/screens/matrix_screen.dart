import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/allocator_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../../models/assignment.dart';
import '../../models/class_model.dart';
import '../../models/education_level.dart';
import '../../models/elective_group.dart';
import '../../models/teacher.dart';
import '../../models/time_slot.dart';
import '../../app_theme.dart';
import '../../utils/responsive.dart';

enum _MatrixView { classPeriod, teacherDay, roomPeriod }

// Ã¢â€â‚¬Ã¢â€â‚¬ Theme helpers Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
extension _MxTh on BuildContext {
  bool get _dk  => Theme.of(this).brightness == Brightness.dark;
  Color get _tp => _dk ? AppTheme.textPrimary   : AppTheme.lightText;
  Color get _ts => _dk ? AppTheme.textSecondary : AppTheme.lightTextSec;
  Color get _tm => _dk ? AppTheme.textMuted     : AppTheme.lightTextMut;
  Color get _hd => _dk ? AppTheme.bgMid         : const Color(0xFFF1F5F9);  // header row bg
  Color get _dv => _dk ? const Color(0xFF1E2D45) : AppTheme.lightDivider;   // row dividers
  Color get _cd => _dk ? AppTheme.bgCard         : Colors.white;             // popup menu bg
  Color get _bd => _dk ? AppTheme.divider        : AppTheme.lightDivider;

  BoxDecoration glassC({double r = 20}) => _dk
      ? AppTheme.glassCard(radius: r)
      : AppTheme.glassCardLight(radius: r);
}

class MatrixScreen extends StatefulWidget {
  const MatrixScreen({super.key});
  @override
  State<MatrixScreen> createState() => _MatrixScreenState();
}


String? formatDaysLabel(List<int> days) {
  if (days.isEmpty) return null;
  if (days.length >= 6 && days.contains(1) && days.contains(2) && days.contains(3) && days.contains(4) && days.contains(5) && days.contains(6)) {
    return null;
  }
  bool consecutive = true;
  for (int i = 1; i < days.length; i++) {
    if (days[i] != days[i - 1] + 1) {
      consecutive = false;
      break;
    }
  }
  if (consecutive && days.length > 1) {
    return '${days.first}-${days.last}';
  } else {
    return days.join(', ');
  }
}

class _MatrixScreenState extends State<MatrixScreen>
    with SingleTickerProviderStateMixin {
  _MatrixView _view = _MatrixView.classPeriod;
  EducationLevel? _level;
  String? _classFilter; // classModel.id — null = all classes
  bool _clashFreeDismissed = false;
  bool _fixingClashes = false;
  bool _suggestingClashes = false;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Suggest Fix dialog: lists every current clash with verified, concrete
  // data-change proposals. Each is applied ONLY via its own Apply button
  // (FixSuggestion.apply re-validates and never touches manual cards).
  Future<void> _showSuggestFixDialog(BuildContext context, DataEntryViewModel dataVm,
      AllocatorViewModel allocVm, int workingDays) {
    final groups = dataVm.suggestFixes(workingDays: workingDays);
    final messenger = ScaffoldMessenger.of(context);
    return showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Suggested Fixes',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 520,
          child: groups.isEmpty
              ? Text('No clashes found — nothing to suggest.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 13))
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final e in groups.entries) ...[
                        Text(e.key,
                            style: GoogleFonts.plusJakartaSans(
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                                color: AppTheme.error)),
                        const SizedBox(height: 6),
                        if (e.value.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                                'No safe automatic option — needs a manual '
                                'decision (e.g. a different teacher, or free '
                                'some space for this class).',
                                style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic)),
                          )
                        else
                          for (final s in e.value)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(children: [
                                Expanded(
                                    child: Text(s.description,
                                        style: GoogleFonts.plusJakartaSans(
                                            fontSize: 12))),
                                const SizedBox(width: 8),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor:
                                          const Color(0xFFB45309)),
                                  onPressed: () {
                                    dataVm.snapshotForUndo(
                                        'Suggest fix: ${s.description}');
                                    final msg = s.apply();
                                    allocVm.validateAndApply(
                                      dataVm.assignments,
                                      dataVm.timeSlots,
                                      combinedRules: dataVm.combinedRules,
                                      rooms: dataVm.rooms,
                                    );
                                    Navigator.of(dCtx).pop();
                                    messenger.showSnackBar(SnackBar(
                                      duration: const Duration(seconds: 6),
                                      content: Text(msg,
                                          style: GoogleFonts.plusJakartaSans(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600)),
                                      backgroundColor: msg.startsWith('Done')
                                          ? AppTheme.accentTeal
                                          : AppTheme.error,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ));
                                  },
                                  child: Text('Apply',
                                      style: GoogleFonts.plusJakartaSans(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 12)),
                                ),
                              ]),
                            ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dCtx).pop(),
              child: Text('Close',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  // "{program}-{class}" (e.g. "ICS Part1-A") so same-named sections across
  // different programs (e.g. two classes both called "A") stay distinguishable.
  String _classChipLabel(DataEntryViewModel dataVm, ClassModel c) {
    final prog = dataVm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? '';
    return prog.isEmpty ? c.name : '$prog-${c.name}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Consumer3<DataEntryViewModel, AllocatorViewModel, SettingsViewModel>(
            builder: (ctx, dataVm, allocVm, settingsVm, _) {
              final hp = ctx.hPad;

              // ── Live clash count ─────────────────────────────────────────────
              final allSlots = dataVm.timeSlots;
              int clashCount = 0;
              final aList = dataVm.combinedAssignments;
              final slotBounds = { for (final t in allSlots) t.id: (s: _parseMin(t.startTime), e: _parseMin(t.endTime)) };

              bool slotsOverlap(String idA, String idB) {
                if (idA == idB) return true;
                final a = slotBounds[idA]; final b = slotBounds[idB];
                if (a == null || b == null) return false;
                return a.s < b.e && b.s < a.e;
              }

              // IDs of assignments actually involved in a clash, so the grid can
              // highlight the exact offending cards instead of only the summary
              // count. Regular assignments are keyed by their real id;
              // elective-derived synthetic assignments (id 'elec_<grp>_<entry>_<class>'
              // from DataEntryViewModel.combinedAssignments) are mapped back to the
              // underlying ElectiveEntry id so the elective-tile renderer can look
              // them up in clashingElectiveEntryIds.
              final clashingAssignmentIds = <String>{};
              final clashingElectiveEntryIds = <String>{};
              void markClash(Assignment x) {
                if (x.id.startsWith('elec_')) {
                  final parts = x.id.split('_');
                  if (parts.length >= 4) clashingElectiveEntryIds.add(parts[2]);
                } else {
                  clashingAssignmentIds.add(x.id);
                }
              }

              // Bucket assignments by timeSlotId so we only ever compare pairs
              // whose slots can actually overlap in real time, instead of an
              // O(n²) scan across every assignment in the school. Distinct
              // time slots (T) is small, so the T×T overlap check below is
              // cheap; assignment-pair work then only happens within buckets
              // that overlap — same result set as the old full pairwise scan.
              final Map<String, List<Assignment>> byTs = {};
              for (final a in aList) { byTs.putIfAbsent(a.timeSlotId, () => []).add(a); }
              final tsIds = byTs.keys.toList();

              // Precompute each assignment's elective-group id once — this was
              // previously re-scanning all electiveGroups for every surviving pair.
              final Map<String, List<ElectiveGroup>> egByOverlappingTs = {
                for (final tsId in tsIds)
                  tsId: dataVm.electiveGroups.where((eg) => slotsOverlap(eg.timeSlotId, tsId)).toList(),
              };
              // Only SYNTHETIC elective cards ('elec_…') belong to a group.
              // A regular course of a member class placed in the elective
              // period is NOT part of the group — if its days overlap the
              // elective's days it must count as a real clash (previously
              // any member-class assignment was silently skipped here).
              final Map<String, String?> egIdCache = {
                for (final a in aList)
                  a.id: a.id.startsWith('elec_')
                      ? egByOverlappingTs[a.timeSlotId]
                          ?.where((eg) => eg.classIds.contains(a.classModel.id))
                          .map((eg) => eg.id)
                          .firstOrNull
                      : null,
              };
              // Rooms deleted from the data can't clash — stale roomIds on
              // assignments must not count.
              final validRoomIds = {for (final r in dataVm.rooms) r.id};

              void checkPair(Assignment a, Assignment b) {
                final shared = a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
                if (shared.isEmpty) return;
                // Skip legitimate combined courses
                if (a.course.id == b.course.id) {
                  final isCombined = dataVm.combinedRules.any((r) =>
                      r.courseId == a.course.id &&
                      r.classIds.contains(a.classModel.id) &&
                      r.classIds.contains(b.classModel.id));
                  if (isCombined) return;
                }
                // Only skip when BOTH assignments belong to the SAME elective group.
                // If a class has an elective AND a regular assignment in the same slot → real clash.
                final aEgId = egIdCache[a.id];
                final bEgId = egIdCache[b.id];
                if (aEgId != null && aEgId == bEgId) return; // same group = intentional split

                if ((a.teacher.id.isNotEmpty && a.teacher.id == b.teacher.id) ||
                    a.classModel.id == b.classModel.id ||
                    (a.hasRoom &&
                        b.hasRoom &&
                        a.roomId == b.roomId &&
                        validRoomIds.contains(a.roomId))) {
                  clashCount++;
                  markClash(a);
                  markClash(b);
                }
              }

              for (int ti = 0; ti < tsIds.length; ti++) {
                final bucketA = byTs[tsIds[ti]]!;
                for (int tj = ti; tj < tsIds.length; tj++) {
                  if (!slotsOverlap(tsIds[ti], tsIds[tj])) continue;
                  if (ti == tj) {
                    for (int i = 0; i < bucketA.length; i++) {
                      for (int j = i + 1; j < bucketA.length; j++) {
                        checkPair(bucketA[i], bucketA[j]);
                      }
                    }
                  } else {
                    final bucketB = byTs[tsIds[tj]]!;
                    for (final a in bucketA) {
                      for (final b in bucketB) {
                        checkPair(a, b);
                      }
                    }
                  }
                }
              }

              return ListView(
                padding: EdgeInsets.fromLTRB(hp, 56, hp, 32),
                children: [
                  _header(ctx, dataVm, allocVm),
                  const SizedBox(height: 16),
                  if (settingsVm.scheduleLocked)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: .45)),
                      ),
                      child: Row(children: [
                        Container(width: 32, height: 32,
                            decoration: BoxDecoration(
                                color: const Color(0xFFEF4444).withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(9)),
                            child: const Icon(Icons.lock_rounded,
                                color: Color(0xFFEF4444), size: 18)),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('🔒  Schedule is Locked',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800,
                                  color: const Color(0xFFEF4444), fontSize: 13)),
                          Text('Go to settings to unlock the schedule to make changes.',
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  color: const Color(0xFFEF4444).withValues(alpha: .85))),
                        ])),
                      ]),
                    ),
                  if (clashCount == 0 && !_clashFreeDismissed)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF059669).withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF059669).withValues(alpha: .45)),
                      ),
                      child: Row(children: [
                        Container(width: 32, height: 32,
                            decoration: BoxDecoration(
                                color: const Color(0xFF059669).withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(9)),
                            child: const Icon(Icons.check_circle_rounded,
                                color: Color(0xFF059669), size: 18)),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('✅  Schedule is clash-free',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF059669), fontSize: 13)),
                          Text('No teacher, class or room overlaps detected.',
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  color: Color(0xFF059669).withValues(alpha: .75))),
                        ])),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => setState(() => _clashFreeDismissed = true),
                          child: Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                                color: const Color(0xFF059669).withValues(alpha: .15),
                                borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.close_rounded,
                                color: Color(0xFF059669), size: 16)),
                        ),
                      ]),
                    ),
                  if (clashCount > 0)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.error.withValues(alpha: .45)),
                      ),
                      child: Row(children: [
                        Container(width: 36, height: 36,
                            decoration: BoxDecoration(
                                color: AppTheme.error.withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.warning_amber_rounded,
                                color: AppTheme.error, size: 20)),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('$clashCount clash${clashCount > 1 ? "es" : ""} found',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.error, fontSize: 14)),
                          Text('Tap Fix Now to auto-resolve teacher, class and room clashes.',
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  color: AppTheme.error.withValues(alpha: .75))),
                        ])),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: _fixingClashes ? null : () async {
                            setState(() => _fixingClashes = true);
                            final messenger = ScaffoldMessenger.of(context);
                            await Future.delayed(Duration.zero);
                            try {
                              dataVm.snapshotForUndo('Fix Now');
                              final msgs = await dataVm.fixTeacherClashes();
                              allocVm.validateAndApply(
                                dataVm.assignments,
                                dataVm.timeSlots,
                                combinedRules: dataVm.combinedRules,
                                rooms: dataVm.rooms,
                              );
                              if (mounted) {
                                messenger.showSnackBar(SnackBar(
                                  duration: const Duration(seconds: 5),
                                  content: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          msgs.isEmpty ? 'No clashes to fix.' : msgs.map((x) => '• $x').join('\n'),
                                          style: GoogleFonts.plusJakartaSans(color: Colors.white, fontSize: 12),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () => messenger.hideCurrentSnackBar(),
                                        child: const Padding(
                                          padding: EdgeInsets.only(left: 8),
                                          child: Icon(Icons.close, color: Colors.white, size: 18),
                                        ),
                                      ),
                                    ],
                                  ),
                                  backgroundColor: msgs.isEmpty ? AppTheme.accentTeal : AppTheme.error,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ));
                              }
                            } finally {
                              if (mounted) setState(() => _fixingClashes = false);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withValues(alpha: _fixingClashes ? .6 : 1),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [BoxShadow(color: AppTheme.error.withValues(alpha: .35), blurRadius: 10, offset: const Offset(0, 3))],
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              if (_fixingClashes)
                                const SizedBox(width: 16, height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              else
                                const Icon(Icons.auto_fix_high_rounded, color: Colors.white, size: 16),
                              const SizedBox(width: 6),
                              Text(_fixingClashes ? 'Fixing…' : 'Fix Now', style: GoogleFonts.plusJakartaSans(
                                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Suggest Fix: what-if engine — proposes verified data
                        // changes (teacher swap / day split / room change);
                        // nothing is applied without an explicit Apply click.
                        GestureDetector(
                          onTap: _suggestingClashes ? null : () {
                            // Re-entrancy guard: suggestFixes() is heavy and
                            // synchronous — without this, rapid taps stacked
                            // several dialogs and compounded the freeze. Flag is
                            // set before the (synchronous) work so re-taps hit
                            // the null onTap; cleared when the dialog closes.
                            setState(() => _suggestingClashes = true);
                            _showSuggestFixDialog(
                                    context, dataVm, allocVm, settingsVm.workingDays)
                                .whenComplete(() {
                              if (mounted) setState(() => _suggestingClashes = false);
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFB45309).withValues(alpha: _suggestingClashes ? .6 : 1),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [BoxShadow(color: const Color(0xFFB45309).withValues(alpha: .35), blurRadius: 10, offset: const Offset(0, 3))],
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              if (_suggestingClashes)
                                const SizedBox(width: 16, height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              else
                                const Icon(Icons.lightbulb_rounded, color: Colors.white, size: 16),
                              const SizedBox(width: 6),
                              Text(_suggestingClashes ? 'Working…' : 'Suggest', style: GoogleFonts.plusJakartaSans(
                                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  _viewToggle(ctx),
                  const SizedBox(height: 12),
                  // ── Search bar ─────────────────────────────────────────────
                  _SearchBar(
                    controller: _searchCtrl,
                    query: _searchQuery,
                    isDark: ctx._dk,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    onClear: () {
                      _searchCtrl.clear();
                      setState(() => _searchQuery = '');
                    },
                    hint: _view == _MatrixView.classPeriod
                        ? 'Search class or program…'
                        : _view == _MatrixView.roomPeriod
                            ? 'Search room…'
                            : 'Search teacher…',
                  ),
                  const SizedBox(height: 16),
                  // Show matrix as soon as assignments exist — no validateAndApply needed
                  if (dataVm.assignments.isEmpty && dataVm.electiveGroups.isEmpty)
                    _emptyState(ctx, true)
                  else if (_view == _MatrixView.classPeriod)
                    _classPeriodMatrix(ctx, dataVm, allocVm, settingsVm, clashingElectiveEntryIds, clashingAssignmentIds)
                  else if (_view == _MatrixView.roomPeriod)
                    _roomPeriodMatrix(ctx, dataVm, settingsVm)
                  else
                    _teacherDayMatrix(ctx, dataVm, allocVm, settingsVm),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext ctx, DataEntryViewModel dataVm, AllocatorViewModel allocVm) =>
      Row(children: [
        Container(width: 48, height: 48,
            decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: allocVm.gaOptimised
                      ? [const Color(0xFF4F46E5), const Color(0xFF7C3AED)]
                      : [const Color(0xFF10B981), const Color(0xFF059669)],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: (allocVm.gaOptimised
                    ? AppTheme.accentViolet : AppTheme.accentTeal).withValues(alpha: .4),
                    blurRadius: 18, offset: const Offset(0,5))]),
            child: Icon(
                allocVm.gaOptimised ? Icons.psychology_rounded : Icons.grid_view_rounded,
                color: Colors.white, size: 24)),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Schedule Matrix', style: GoogleFonts.plusJakartaSans(
              fontSize: 24, fontWeight: FontWeight.w800,
              color: ctx._tp, letterSpacing: -0.5)),
          Text('Clash-free timetable - two switchable views',
              style: GoogleFonts.plusJakartaSans(fontSize: 13, color: ctx._ts)),
        ]),
        const Spacer(),
        if (allocVm.hasSchedule) Row(children: [
          GestureDetector(
            onTap: () => _showFilterPanel(ctx, dataVm),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: (_level != null || _classFilter != null)
                    ? AppTheme.accentViolet.withValues(alpha: .12)
                    : ctx._hd,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: (_level != null || _classFilter != null)
                    ? AppTheme.accentViolet.withValues(alpha: .5)
                    : ctx._bd),
              ),
              child: Row(children: [
                Icon(Icons.filter_list_rounded,
                    color: (_level != null || _classFilter != null) ? AppTheme.accentViolet : ctx._ts,
                    size: 16),
                const SizedBox(width: 6),
                Text(
                  _classFilter != null
                      ? (dataVm.classes.where((c) => c.id == _classFilter).firstOrNull != null
                          ? _classChipLabel(dataVm, dataVm.classes.where((c) => c.id == _classFilter).first)
                          : 'Class')
                      : (_level == EducationLevel.intermediate ? 'Intermediate'
                          : _level == EducationLevel.bachelors ? 'Bachelors' : 'All Levels'),
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700,
                      color: (_level != null || _classFilter != null) ? AppTheme.accentViolet : ctx._tp,
                      fontSize: 12),
                ),
                const SizedBox(width: 2),
                Icon(Icons.arrow_drop_down_rounded,
                    color: (_level != null || _classFilter != null) ? AppTheme.accentViolet : ctx._ts,
                    size: 16),
              ]),
            ),
          ),
          const SizedBox(width: 12),

          // ── Teacher Transfers button ──────────────────────────────────
          GestureDetector(
            onTap: () => _showTransferDialog(ctx, dataVm),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF97316).withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF97316).withValues(alpha: .45)),
              ),
              child: Row(children: [
                const Icon(Icons.swap_horiz_rounded, color: Color(0xFFF97316), size: 18),
                const SizedBox(width: 8),
                Text('Transfers & Swap', style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: const Color(0xFFF97316), fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(width: 12),

          // ── Move Course button — relocate a single card to a different
          // period, keeping teacher/days/room untouched. Separate from
          // Transfers & Swap, which only exchanges teachers within a class.
          GestureDetector(
            onTap: () => showDialog(
              context: ctx,
              barrierDismissible: false,
              builder: (_) => _MoveCourseDialog(dataVm: dataVm),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.accentCyan.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentCyan.withValues(alpha: .45)),
              ),
              child: Row(children: [
                const Icon(Icons.open_with_rounded, color: AppTheme.accentCyan, size: 18),
                const SizedBox(width: 8),
                Text('Move Course', style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: AppTheme.accentCyan, fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          PopupMenuButton<String>(
            tooltip: 'Export Options',
            color: ctx._cd,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: ctx._bd)),
            offset: const Offset(0, 50),
            onSelected: (value) async {
              final type   = value.endsWith('student') ? ExportType.studentWise : ExportType.teacherWise;
              try {
                final levelSlots = _level == null ? dataVm.timeSlots.toList() : dataVm.timeSlots.where((t) => t.level == _level).toList();
                final savedPath = await allocVm.exportSchedule(
                    format: ExportFormat.excel, type: type, timeSlots: levelSlots,
                    rooms: dataVm.rooms, classes: dataVm.classes, electiveGroups: dataVm.electiveGroups);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    duration: const Duration(seconds: 6),
                    content: Row(children: [
                      const Icon(Icons.check_circle_rounded,
                          color: Colors.white, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Saved to Downloads!',
                              style: GoogleFonts.plusJakartaSans(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800, fontSize: 13)),
                          Text(savedPath,
                              style: GoogleFonts.plusJakartaSans(
                                  color: Colors.white70, fontSize: 10),
                              overflow: TextOverflow.ellipsis),
                        ],
                      )),
                    ]),
                    backgroundColor: AppTheme.accentTeal,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ));
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Export failed: $e',
                        style: GoogleFonts.plusJakartaSans(color: Colors.white)),
                    backgroundColor: AppTheme.error,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ));
                }
              }
            },
            itemBuilder: (context) => [
              _buildPopupItem(ctx, 'excel_student', Icons.table_chart_rounded, 'Excel — Class Wise',   AppTheme.accentTeal),
              _buildPopupItem(ctx, 'excel_teacher', Icons.table_chart_rounded, 'Excel — Teacher Wise', AppTheme.accentTeal),
            ],
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: AppTheme.accentTeal.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.accentTeal.withValues(alpha: .4))),
              child: Row(children: [
                const Icon(Icons.download_rounded, color: AppTheme.accentTeal, size: 18),
                const SizedBox(width: 8),
                Text('Export', style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: AppTheme.accentTeal, fontSize: 13)),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down_rounded, color: AppTheme.accentTeal, size: 18),
              ]),
            ),
          ),
        ]),
      ]);



  // ── Compact Filter Panel ─────────────────────────────────────────────────
  void _showFilterPanel(BuildContext ctx, DataEntryViewModel dataVm) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final cd  = isDark ? const Color(0xFF1E293B) : Colors.white;
    final bd  = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final ts  = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    const violet = AppTheme.accentViolet;
    const cyan   = AppTheme.accentCyan;

    EducationLevel? tmpLevel   = _level;
    String?         tmpClass   = _classFilter;

    final allClasses = dataVm.classes.toList()
      ..sort((a, b) => _classChipLabel(dataVm, a).compareTo(_classChipLabel(dataVm, b)));

    showDialog(
      context: ctx,
      barrierColor: Colors.black.withValues(alpha: .15),
      barrierDismissible: true,
      builder: (_) => Align(
        alignment: const Alignment(0.6, -0.72), // near top-right under filter button
        child: StatefulBuilder(builder: (bCtx, setSt) {
          final visibleClasses = tmpLevel == null
              ? allClasses
              : allClasses.where((c) => c.level == tmpLevel).toList();

          return Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(bCtx).size.height * 0.75),
              child: Container(
              width: 420,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cd,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: bd),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .18), blurRadius: 24, offset: const Offset(0, 8))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row
                  Row(children: [
                    Icon(Icons.filter_list_rounded, size: 15, color: violet),
                    const SizedBox(width: 6),
                    Text('Filter', style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800, fontSize: 14, color: isDark ? Colors.white : const Color(0xFF0F172A))),
                    const Spacer(),
                    if (tmpLevel != null || tmpClass != null)
                      GestureDetector(
                        onTap: () { setSt(() { tmpLevel = null; tmpClass = null; }); setState(() { _level = null; _classFilter = null; }); Navigator.pop(bCtx); },
                        child: Text('Clear', style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700, color: violet)),
                      ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => Navigator.pop(bCtx),
                      child: Icon(Icons.close_rounded, size: 16, color: ts),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // ── Level row ─────────────────────────────────────────
                  Text('LEVEL', style: GoogleFonts.plusJakartaSans(fontSize: 9, fontWeight: FontWeight.w800, color: ts, letterSpacing: 1.2)),
                  const SizedBox(height: 6),
                  Row(children: [
                    _filterChip(bCtx, 'All', tmpLevel == null, violet, isDark, () {
                      setSt(() { tmpLevel = null; tmpClass = null; });
                      setState(() { _level = null; _classFilter = null; });
                    }),
                    const SizedBox(width: 6),
                    _filterChip(bCtx, 'Intermediate', tmpLevel == EducationLevel.intermediate, violet, isDark, () {
                      setSt(() { tmpLevel = EducationLevel.intermediate; tmpClass = null; });
                      setState(() { _level = EducationLevel.intermediate; _classFilter = null; });
                    }),
                    const SizedBox(width: 6),
                    _filterChip(bCtx, 'Bachelors', tmpLevel == EducationLevel.bachelors, cyan, isDark, () {
                      setSt(() { tmpLevel = EducationLevel.bachelors; tmpClass = null; });
                      setState(() { _level = EducationLevel.bachelors; _classFilter = null; });
                    }),
                  ]),
                  const SizedBox(height: 12),

                  // ── Class chips ───────────────────────────────────────
                  Text('CLASS / SECTION', style: GoogleFonts.plusJakartaSans(fontSize: 9, fontWeight: FontWeight.w800, color: ts, letterSpacing: 1.2)),
                  const SizedBox(height: 6),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 6, runSpacing: 6,
                        children: [
                          _filterChip(bCtx, 'All Classes', tmpClass == null, violet, isDark, () {
                            setSt(() => tmpClass = null);
                            setState(() => _classFilter = null);
                          }),
                          ...visibleClasses.map((c) {
                            final isBach = c.level == EducationLevel.bachelors;
                            return _filterChip(bCtx, _classChipLabel(dataVm, c), tmpClass == c.id, isBach ? cyan : violet, isDark, () {
                              setSt(() => tmpClass = c.id);
                              setState(() => _classFilter = c.id);
                            });
                          }),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ),
          );
        }),
      ),
    );
  }

  Widget _filterChip(BuildContext ctx, String label, bool selected, Color color, bool isDark, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: .15) : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color.withValues(alpha: .6) : Colors.transparent, width: 1.5),
        ),
        child: Text(label, style: GoogleFonts.plusJakartaSans(
            fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? color : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)))),
      ),
    );
  }

  // ── Batch Teacher Transfer Dialog ────────────────────────────────────────

  void _showTransferDialog(BuildContext ctx, DataEntryViewModel dataVm) {
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _TeacherTransferDialog(dataVm: dataVm),
    );
  }

  PopupMenuItem<String> _buildPopupItem(BuildContext ctx, String value, IconData icon, String text, Color color) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Text(text, style: GoogleFonts.plusJakartaSans(
            fontSize: 13, color: ctx._tp, fontWeight: FontWeight.w600)),
      ]),
    );
  }



  Widget _viewToggle(BuildContext ctx) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
        color: ctx._hd,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ctx._bd)),
    child: Row(children: [
      _ViewTab(
          icon: Icons.table_chart_rounded,
          label: 'Class-wise',
          sublabel: 'View timetable by classes',
          selected: _view == _MatrixView.classPeriod,
          color: AppTheme.accentCyan,
          onTap: () => setState(() => _view = _MatrixView.classPeriod)),
      _ViewTab(
          icon: Icons.person_rounded,
          label: 'Teacher-wise',
          sublabel: 'View timetable by teachers',
          selected: _view == _MatrixView.teacherDay,
          color: AppTheme.accentViolet,
          onTap: () => setState(() => _view = _MatrixView.teacherDay)),
      _ViewTab(
          icon: Icons.meeting_room_rounded,
          label: 'Room-wise',
          sublabel: 'View timetable by rooms',
          selected: _view == _MatrixView.roomPeriod,
          color: AppTheme.accentAmber,
          onTap: () => setState(() => _view = _MatrixView.roomPeriod)),
    ]),
  );



  Widget _emptyState(BuildContext ctx, bool noAssignments) => Container(
    padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 40),
    decoration: ctx.glassC(r: 24),
    child: Column(children: [
      Container(width: 72, height: 72,
          decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: AppTheme.accentTeal.withValues(alpha: .35),
                  blurRadius: 20, offset: const Offset(0,6))]),
          child: const Icon(Icons.grid_view_rounded, size: 34, color: Colors.white)),
      const SizedBox(height: 24),
      Text(noAssignments ? 'No assignments yet' : 'Schedule not generated',
          style: GoogleFonts.plusJakartaSans(fontSize: 20,
              fontWeight: FontWeight.w700, color: ctx._tp)),
      const SizedBox(height: 10),
      Text(noAssignments
          ? 'Add data in Manage Data, then assign slots in the Allocator tab.'
          : 'Go to Allocator and press Run Clash Validator to build the matrix.',
          textAlign: TextAlign.center, style: GoogleFonts.plusJakartaSans(
              fontSize: 14, color: ctx._ts, height: 1.6)),
    ]),
  );

  /// Displayed when the search filter yields no matching rows.
  Widget _noResults(BuildContext ctx) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 56),
    child: Column(
      children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            color: AppTheme.accentViolet.withValues(alpha: .12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.search_off_rounded,
              size: 28, color: AppTheme.accentViolet),
        ),
        const SizedBox(height: 14),
        Text('No results',
            style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, fontSize: 16, color: ctx._tp)),
        const SizedBox(height: 4),
        Text('Try a different search term or clear the filter',
            style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._ts)),
      ],
    ),
  );

  // parse "HH:mm" Ã¢â€ â€™ minutes since midnight
  static int _parseMin(String t) {
    final p = t.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬ VIEW 1: Class x Period Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  Widget _classPeriodMatrix(BuildContext ctx, DataEntryViewModel dataVm, AllocatorViewModel allocVm, SettingsViewModel settingsVm, Set<String> clashingElectiveEntryIds, Set<String> clashingAssignmentIds) {
    final allSlots = dataVm.timeSlots.toList()..sort((a, b) {
      final lc = a.level.index.compareTo(b.level.index);
      return lc != 0 ? lc : a.period.compareTo(b.period);
    });

    // Show ALL configured slots â€” maxPeriods only limits GA engine, not display
    final bachSlots  = allSlots.where((t) => t.level == EducationLevel.bachelors).toList();
    final interSlots = allSlots.where((t) => t.level == EducationLevel.intermediate).toList();
    final singleLevel = _level != null;
    final filteredSlots = (singleLevel ? allSlots.where((t) => t.level == _level) : allSlots).toList();


    if (filteredSlots.isEmpty) {
      return _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentCyan,
          text: 'No time slots configured. Add periods in Manage Data and Time Slots.');
    }

    final progById = {for (final p in dataVm.programs) p.id: p.name};
    final classById = {for (final c in dataVm.classes) c.id: c};
    final roomById = {for (final r in dataVm.rooms) r.id: r.name};
    // Use real (non-synthetic) assignments only — elective groups are shown separately via egMap.
    final source = dataVm.assignments;

    // Precomputed classId+timeSlotId → ElectiveGroup lookup, built once in
    // O(electiveGroups × classesPerGroup). Replaces dataVm.electiveGroupFor()
    // (a linear scan of all elective groups) which was being called inside a
    // per-row × per-slot × neighbor-scan loop below — O(n²) at scale.
    final Map<String, Map<String, ElectiveGroup>> egLookup = {};
    for (final eg in dataVm.electiveGroups) {
      for (final cid in eg.classIds) {
        egLookup.putIfAbsent(cid, () => {})[eg.timeSlotId] = eg;
      }
    }
    ElectiveGroup? egFor(String classId, String timeSlotId) => egLookup[classId]?[timeSlotId];

    final Map<String, List<Assignment>> byClass = {};
    for (final a in source.where((x) =>
        (_level == null || x.classModel.level == _level) &&
        (_classFilter == null || x.classModel.id == _classFilter))) {
      byClass.putIfAbsent(a.classModel.id, () => []).add(a);
    }

    // Also include classes that only appear in elective groups (no regular assignments yet)
    for (final grp in dataVm.electiveGroups) {
      for (final cid in grp.classIds) {
        final cls = classById[cid];
        if (cls != null &&
            (_level == null || cls.level == _level) &&
            (_classFilter == null || cls.id == _classFilter)) {
          byClass.putIfAbsent(cid, () => []);
        }
      }
    }

    if (byClass.isEmpty) return _emptyState(ctx, false);

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      byClass.removeWhere((cid, _) {
        final cls = classById[cid];
        if (cls == null) return true;
        return !cls.name.toLowerCase().contains(q) &&
            !cls.shortCode.toLowerCase().contains(q) &&
            !(progById[cls.programId] ?? '').toLowerCase().contains(q);
      });
    }
    if (byClass.isEmpty) return _noResults(ctx);

    final classIds = byClass.keys.toList()..sort((a, b) {
      ClassModel? ca = byClass[a]?.firstOrNull?.classModel ?? classById[a];
      ClassModel? cb = byClass[b]?.firstOrNull?.classModel ?? classById[b];
      if (ca == null || cb == null) return a.compareTo(b);
      final pa = progById[ca.programId] ?? '';
      final pb = progById[cb.programId] ?? '';
      final c0 = pa.compareTo(pb);
      return c0 != 0 ? c0 : ca.name.compareTo(cb.name);
    });

    // Re-order so all classes in the same elective group appear consecutively.
    // This lets the samePrev/sameNext block-merge logic produce ONE visual block.
    final List<String> reordered = [];
    final Set<String> placed = {};
    for (final cid in classIds) {
      if (placed.contains(cid)) continue;
      reordered.add(cid);
      placed.add(cid);
      // Find any elective groups this class participates in
      for (final eg in dataVm.electiveGroups) {
        if (!eg.classIds.contains(cid)) continue;
        // Append sibling classes (in original sort order) right after this one
        for (final sibling in classIds) {
          if (!placed.contains(sibling) && eg.classIds.contains(sibling)) {
            reordered.add(sibling);
            placed.add(sibling);
          }
        }
      }
    }
    // Replace classIds with the grouped ordering
    classIds
      ..clear()
      ..addAll(reordered);

    return LayoutBuilder(builder: (ctx2, constraints) {
      final avail   = constraints.maxWidth;
      final rowLblW = avail < 420 ? 100.0 : avail < 600 ? 130.0 : 190.0;

      // Ã¢â€â‚¬Ã¢â€â‚¬ Time-proportional widths Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      // pxPerMin: each minute of real time = this many pixels.
      // 4 px/min Ã¢â€ â€™ 60 min(bach) = 240px, 40 min(inter) = 160px
      // 2 bach (120min=480px) == 3 inter (120min=480px) Ã¢â€ â€™ perfect alignment.
      const double pxPerMin = 4.0;

      int parseMin(String t) => _parseMin(t);

      // Global time bounds (union of both levels)
      final allStarts = filteredSlots.map((t) => parseMin(t.startTime));
      final allEnds   = filteredSlots.map((t) => parseMin(t.endTime));
      final globalStart = allStarts.reduce((a, b) => a < b ? a : b);
      final globalEnd   = allEnds.reduce((a, b) => a > b ? a : b);

      // Width of a slot in pixels
      double slotW(ts) => math.max(0.0, (parseMin(ts.endTime) - parseMin(ts.startTime)) * pxPerMin);
      // Leading gap of a slot from globalStart
      double slotOffset(ts) => math.max(0.0, (parseMin(ts.startTime) - globalStart) * pxPerMin);
      // Total timeline width (excluding label column)
      final timelineW = math.max(0.0, (globalEnd - globalStart) * pxPerMin);

      // ── period header cell (proportional width) ──────────────────────────
      // Shared period header — used by both class-wise and teacher-wise
      Widget periodHeader(ts, Color accent) {
        final w = slotW(ts);
        return SizedBox(width: w, child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(ts.shortLabel, style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, fontSize: 10, color: accent),
                textAlign: TextAlign.center),
            Text('${ts.startTime}-${ts.endTime}', style: GoogleFonts.plusJakartaSans(
                fontSize: 7, color: ctx._tm), textAlign: TextAlign.center),
            if (ts.hasFridayOverride)
              Text('Fri ${ts.fridayLabel}', style: GoogleFonts.plusJakartaSans(
                  fontSize: 7, color: AppTheme.accentAmber), textAlign: TextAlign.center),
              if (settingsVm.fridayShortDay && ts.period > settingsVm.fridayMaxPeriod)
                Container(margin: const EdgeInsets.only(top: 2), padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: const Color(0xFFEF4444).withValues(alpha: .12), borderRadius: BorderRadius.circular(4)), child: Text('Fri off', style: GoogleFonts.plusJakartaSans(fontSize: 6, fontWeight: FontWeight.w800, color: const Color(0xFFEF4444)))), 
          ]),
        ));
      }

      // ── assignment cell ─ shows ALL assignments sharing this time slot ──
      // [aList] = all assignments for this class at this time slot
      // [eg]    = optional ElectiveGroup covering this class at this slot.
      Widget assignCell(ts, List<Assignment> aList, {ElectiveGroup? eg, bool samePrev = false, bool sameNext = false, int span = 1, int indexInGroup = 0}) {
        final w = slotW(ts);

        // ── Elective group cell ───────────────────────────────────────────────
        if (eg != null) {
          final bool groupHasClash = eg.entries.any((e) => clashingElectiveEntryIds.contains(e.id));
          final col = groupHasClash ? AppTheme.error : AppTheme.accentAmber;
          final int N = eg.entries.length;

          List<int> startIndex = List.filled(span, 0);
          List<int> cardsInBucket = List.filled(span, 0);
          for (int i = 0; i < N; i++) {
            int b = (i * span) ~/ N;
            if (b >= span) b = span - 1;
            cardsInBucket[b]++;
          }
          int acc = 0;
          for (int b = 0; b < span; b++) {
            startIndex[b] = acc;
            acc += cardsInBucket[b];
          }
          final int myBucket = samePrev ? indexInGroup : 0;
          final int myCardStart = startIndex[myBucket];
          final int myCardCount = cardsInBucket[myBucket];
          final bool isFirst = !samePrev;
          final bool isLast = !sameNext;
          final int maxCardsInBucket = cardsInBucket.reduce((a, b) => a > b ? a : b);
          final myCards = eg.entries.sublist(myCardStart, myCardStart + myCardCount);
          final int ghostCount = maxCardsInBucket - myCardCount;

          final Widget electiveWidget = ClipRect(
            child: SizedBox(
              width: w,
              child: Container(
              margin: EdgeInsets.only(
                left: 2, right: 2,
                top: isFirst ? 3 : 0,
                bottom: 0,
              ),
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: col.withValues(alpha: .08),
                borderRadius: BorderRadius.only(
                  topLeft:     isFirst ? const Radius.circular(9) : Radius.zero,
                  topRight:    isFirst ? const Radius.circular(9) : Radius.zero,
                  bottomLeft:  isLast  ? const Radius.circular(9) : Radius.zero,
                  bottomRight: isLast  ? const Radius.circular(9) : Radius.zero,
                ),
                border: Border(
                  left:   BorderSide(color: col.withValues(alpha: .45), width: 1),
                  right:  BorderSide(color: col.withValues(alpha: .45), width: 1),
                  top:    isFirst ? BorderSide(color: col.withValues(alpha: .45), width: 1) : BorderSide.none,
                  bottom: isLast  ? BorderSide(color: col.withValues(alpha: .45), width: 1) : BorderSide.none,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  for (int i = 0; i < myCards.length; i++) ...[
                    if (i > 0) const SizedBox(height: 4),
                    () {
                      final e = myCards[i];
                      final isEntryClash = clashingElectiveEntryIds.contains(e.id);
                      // Only the actually-clashing entry renders red — a sibling
                      // clash elsewhere in the group shouldn't paint every card.
                      final cardCol = isEntryClash ? AppTheme.error : AppTheme.accentAmber;
                      final hasRoom = e.roomLabel != null && e.roomLabel!.isNotEmpty;
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: cardCol.withValues(alpha: isEntryClash ? .15 : .10),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: cardCol.withValues(alpha: isEntryClash ? .7 : .3), width: isEntryClash ? 1.5 : 1),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(children: [
                              if (isEntryClash) ...[
                                Icon(Icons.warning_rounded, size: 9, color: cardCol),
                                const SizedBox(width: 3),
                              ],
                              Expanded(child: Text(e.courseName, style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800, fontSize: 10, color: cardCol),
                                  overflow: TextOverflow.ellipsis, maxLines: 1)),
                            ]),
                            const SizedBox(height: 2),
                            Text(e.teacherName, style: GoogleFonts.plusJakartaSans(
                                fontSize: 8, color: isEntryClash ? cardCol.withValues(alpha: .8) : ctx._ts),
                                overflow: TextOverflow.ellipsis),
                            if (hasRoom) ...[
                              const SizedBox(height: 1),
                              Row(children: [
                                Icon(Icons.meeting_room_rounded, size: 8, color: cardCol),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Text(e.roomLabel!, style: GoogleFonts.plusJakartaSans(
                                      fontSize: 8, fontWeight: FontWeight.w700, color: cardCol),
                                      overflow: TextOverflow.ellipsis, maxLines: 1),
                                ),
                              ]),
                            ],
                          ],
                        ),
                      );
                    }(),
                  ],
                  for (int g = 0; g < ghostCount; g++) ...[
                    if (myCardCount > 0 || g > 0) const SizedBox(height: 4),
                    Opacity(
                      opacity: 0,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(9)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Ghost', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 10),
                                overflow: TextOverflow.ellipsis, maxLines: 1),
                            const SizedBox(height: 2),
                            Text('Ghost teacher', style: GoogleFonts.plusJakartaSans(fontSize: 8),
                                overflow: TextOverflow.ellipsis, maxLines: 1),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ),
          );

          // If no regular assignments also in this slot → render elective only
          if (aList.isEmpty) return electiveWidget;

          // Regular assignments exist alongside elective → show as clash below
          final Map<String, List<Assignment>> grpd = {};
          for (final a in aList) { grpd.putIfAbsent('${a.course.id}__${a.teacher.id}', () => []).add(a); }
          final List<Widget> clashCards = grpd.values.map((group) {
            final a = group.first;
            final errCol = AppTheme.error;
            final allDays = group.expand((x) => x.occupiedSlots).toSet().toList()..sort();
            return Container(
              margin: const EdgeInsets.only(left: 2, right: 2, bottom: 3),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: errCol.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: errCol.withValues(alpha: .7), width: 1.5),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.warning_rounded, size: 9, color: errCol),
                  const SizedBox(width: 3),
                  Expanded(child: Text(a.course.name, style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: errCol, fontSize: 10),
                      overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]),
                const SizedBox(height: 2),
                Text(a.teacher.name, style: GoogleFonts.plusJakartaSans(
                    fontSize: 8, color: errCol.withValues(alpha: .8)), overflow: TextOverflow.ellipsis, maxLines: 1),
                if (formatDaysLabel(allDays) != null) Row(children: [
                  Icon(Icons.calendar_today_rounded, size: 7, color: ctx._tm),
                  const SizedBox(width: 2),
                  Flexible(child: Text('Days: ${formatDaysLabel(allDays)}', style: GoogleFonts.plusJakartaSans(
                      fontSize: 8, fontWeight: FontWeight.w700, color: ctx._tm),
                      overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]),
              ]),
            );
          }).toList();

          return ClipRect(child: Container(
            width: w,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx._dv, width: 1))),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              electiveWidget,
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: .12),
                  border: Border.symmetric(
                    horizontal: BorderSide(color: AppTheme.error.withValues(alpha: .5), width: 1),
                  ),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.warning_amber_rounded, size: 9, color: AppTheme.error),
                  const SizedBox(width: 3),
                  Text('CLASH', style: GoogleFonts.plusJakartaSans(
                      fontSize: 8, fontWeight: FontWeight.w900, color: AppTheme.error)),
                ]),
              ),
              ...clashCards,
            ]),
          ));
        }

        // ── Regular-only cell (no elective) ──────────────────────────────────
        if (aList.isEmpty) { return ClipRect(child: Container(
            width: w,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx._dv, width: 1))),
            child: Center(child: Text('-', style: TextStyle(
                color: ctx._dk ? const Color(0xFF2A3A55) : const Color(0xFFCBD5E1),
                fontSize: 12))))); }

        final Map<String, List<Assignment>> grouped = {};
        for (final a in aList) { grouped.putIfAbsent('${a.course.id}__${a.teacher.id}', () => []).add(a); }

        return ClipRect(child: Container(
          width: w,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx._dv, width: 1))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: grouped.values.map((group) {
              final a   = group.first;
              final isClash = group.any((x) => clashingAssignmentIds.contains(x.id));
              final col = isClash ? AppTheme.error
                  : a.classModel.level == EducationLevel.bachelors
                      ? AppTheme.accentCyan : AppTheme.accentViolet;
              final allDays = group.expand((x) => x.occupiedSlots).toSet().toList()..sort();
              return Container(
                margin: const EdgeInsets.all(3),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: col.withValues(alpha: isClash ? .15 : .1),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: col.withValues(alpha: isClash ? .7 : .3), width: isClash ? 1.5 : 1)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (isClash) ...[
                      Icon(Icons.warning_rounded, size: 9, color: col),
                      const SizedBox(width: 3),
                    ],
                    Expanded(child: Text(a.course.name, style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800, color: col, fontSize: 10),
                        overflow: TextOverflow.ellipsis, maxLines: 1)),
                  ]),
                  const SizedBox(height: 2),
                  Text(a.teacher.name, style: GoogleFonts.plusJakartaSans(
                      fontSize: 8, color: ctx._ts), overflow: TextOverflow.ellipsis, maxLines: 1),
                  if (formatDaysLabel(allDays) != null) Row(children: [
                    Icon(Icons.calendar_today_rounded, size: 7, color: ctx._tm),
                    const SizedBox(width: 2),
                    Flexible(child: Text('Days: ${formatDaysLabel(allDays)}', style: GoogleFonts.plusJakartaSans(
                        fontSize: 8, fontWeight: FontWeight.w700, color: ctx._tm),
                        overflow: TextOverflow.ellipsis, maxLines: 1)),
                  ]),
                  if (a.hasRoom) ...[
                    const SizedBox(height: 1),
                    Row(children: [
                      Icon(Icons.meeting_room_rounded, size: 7, color: ctx._tm),
                      const SizedBox(width: 2),
                      Flexible(child: Text(roomById[a.roomId] ?? 'Unknown', style: GoogleFonts.plusJakartaSans(
                          fontSize: 8, fontWeight: FontWeight.w700, color: ctx._tm),
                          overflow: TextOverflow.ellipsis, maxLines: 1)),
                    ]),
                  ],
                ]));
            }).toList(),
          )));
      }


      // ── Build a timeline row: label + slots positioned on global time axis ──
      Widget timelineRow(List slots, Map<String, List<Assignment>> pMap,
          {required bool showSlots, Map<String, ElectiveGroup>? egMap, Map<String, Map<String, dynamic>>? mergeMap}) {
        if (slots.isEmpty) return SizedBox(width: timelineW);
        final lead  = slotOffset(slots.first);
        final trail = timelineW - lead - slots.fold(0.0, (s, t) => s + slotW(t));
        return SizedBox(
          width: timelineW,
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: showSlots ? CrossAxisAlignment.stretch : CrossAxisAlignment.start, children: [
            if (lead > 0)   SizedBox(width: lead, child: showSlots ? Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx._dv, width: 1)))) : null),
            ...slots.map((ts) => showSlots
                ? assignCell(ts, pMap[ts.id] ?? [], eg: egMap?[ts.id], samePrev: mergeMap?[ts.id]?['prev'] ?? false, sameNext: mergeMap?[ts.id]?['next'] ?? false, span: mergeMap?[ts.id]?['span'] ?? 1, indexInGroup: mergeMap?[ts.id]?['indexInGroup'] ?? 0)
                : periodHeader(ts, ts.level == EducationLevel.bachelors ? AppTheme.accentCyan : AppTheme.accentViolet)),
            if (trail > 0)  SizedBox(width: trail, child: showSlots ? Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx._dv, width: 1)))) : null),
          ]),
        );
      }

      // ── label cell ──────────────────────────────────────────────────────────────────
      Widget labelCell(String classId) {
        final asgns      = byClass[classId] ?? [];
        // For classes with only elective groups (no regular assignments), fall back to classById
        final classModel = asgns.isNotEmpty ? asgns.first.classModel : classById[classId];
        if (classModel == null) return SizedBox(width: rowLblW);
        final programName = progById[classModel.programId] ?? '';
        final isBach     = classModel.level == EducationLevel.bachelors;
        return Container(
            width: rowLblW,
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx._dv, width: 1))),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (programName.isNotEmpty)
                Text(programName, style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    color: isBach ? AppTheme.accentCyan : AppTheme.accentViolet,
                    fontSize: 10), overflow: TextOverflow.ellipsis, maxLines: 1),
              Text(classModel.name, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, color: ctx._tp, fontSize: 11),
                  overflow: TextOverflow.ellipsis),
              Row(children: [
                Text('${asgns.length} subj', style: GoogleFonts.plusJakartaSans(
                    fontSize: 9, color: ctx._tm)),

              ]),
            ]));
      }

      // Explicit total row width — avoids IntrinsicWidth's O(n) measurement
      // that broke alignment at 100+ rows. Every row now gets exact pixels.
      final totalW = rowLblW + timelineW;

      return Container(
        decoration: ctx.glassC(r: 20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalW,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── HEADERS ──────────────────────────────────────────────────
                  if (singleLevel) ...[
                    Container(color: ctx._hd, child: Row(children: [
                      SizedBox(width: rowLblW, child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('Class', style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700, fontSize: 11, color: ctx._ts)))),
                      timelineRow(filteredSlots, {}, showSlots: false),
                    ])),
                  ] else ...[
                    if (bachSlots.isNotEmpty)
                      Container(color: AppTheme.accentCyan.withValues(alpha: .07), child: Row(children: [
                        SizedBox(width: rowLblW, child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: Text('Bach', style: GoogleFonts.plusJakartaSans(
                                fontWeight: FontWeight.w800, fontSize: 10, color: AppTheme.accentCyan)))),
                        timelineRow(bachSlots, {}, showSlots: false),
                      ])),
                    if (interSlots.isNotEmpty)
                      Container(color: AppTheme.accentViolet.withValues(alpha: .07), child: Row(children: [
                        SizedBox(width: rowLblW, child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: Text('Inter', style: GoogleFonts.plusJakartaSans(
                                fontWeight: FontWeight.w800, fontSize: 10, color: AppTheme.accentViolet)))),
                        timelineRow(interSlots, {}, showSlots: false),
                      ])),
                  ],
                  Divider(color: ctx._dv, height: 1),

                  // ── DATA ROWS ─────────────────────────────────────────────────
                  ...classIds.asMap().entries.map((entry) {
                    final cIdx    = entry.key;
                    final classId = entry.value;
                    final asgns   = byClass[classId] ?? [];
                    final rowClassModel = asgns.isNotEmpty ? asgns.first.classModel : classById[classId];
                    final isBach  = rowClassModel?.level == EducationLevel.bachelors;
                    final Map<String, List<Assignment>> pMap = {};
                    for (final a in asgns) { pMap.putIfAbsent(a.timeSlotId, () => []).add(a); }

                    final slots = singleLevel ? filteredSlots
                        : (isBach ? bachSlots : interSlots);

                    final Map<String, ElectiveGroup> egMap = {};
                    final Map<String, Map<String, dynamic>> mergeMap = {};
                    for (final ts in slots) {
                      final eg = egFor(classId, ts.id);
                      if (eg != null) {
                        egMap[ts.id] = eg;
                        final prevClass = cIdx > 0 ? classIds[cIdx - 1] : null;
                        final nextClass = cIdx < classIds.length - 1 ? classIds[cIdx + 1] : null;
                        final prevEg = prevClass != null ? egFor(prevClass, ts.id) : null;
                        final nextEg = nextClass != null ? egFor(nextClass, ts.id) : null;

                        int spanBack = 0;
                        for (int i = cIdx - 1; i >= 0; i--) {
                          if (egFor(classIds[i], ts.id)?.id == eg.id) { spanBack++; } else { break; }
                        }
                        int spanFwd = 0;
                        for (int i = cIdx + 1; i < classIds.length; i++) {
                          if (egFor(classIds[i], ts.id)?.id == eg.id) { spanFwd++; } else { break; }
                        }
                        mergeMap[ts.id] = {
                          'prev': prevEg?.id == eg.id,
                          'next': nextEg?.id == eg.id,
                          'span': spanBack + spanFwd + 1,
                          'indexInGroup': spanBack,
                        };
                      }
                    }

                    return IntrinsicHeight(
                      child: SizedBox(
                        width: totalW,
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          labelCell(classId),
                          timelineRow(slots, pMap, showSlots: true, egMap: egMap, mergeMap: mergeMap),
                        ]),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }


  // ── VIEW 3: Room × Period Matrix ──────────────────────────────────────────
  Widget _roomPeriodMatrix(
      BuildContext ctx, DataEntryViewModel dataVm, SettingsViewModel settingsVm) {
    // Include elective entries so elective teachers appear in their slot.
    // One elective entry teaches multiple classes SIMULTANEOUSLY — dedupe by
    // (group, entry) so the teacher's cell shows the lecture once, not per class.
    // Build source: keep ALL per-class assignments so level filter works correctly.
    // Dedup will happen per room+slot combination below.
    final source = List<Assignment>.from(dataVm.combinedAssignments);
    if (source.isEmpty && dataVm.electiveGroups.isEmpty) return _emptyState(ctx, false);

    // Same slot setup as classPeriodMatrix
    final allSlots = dataVm.timeSlots.toList()..sort((a, b) {
      final lc = a.level.index.compareTo(b.level.index);
      return lc != 0 ? lc : a.period.compareTo(b.period);
    });
    // Show ALL configured slots
    final bachSlots  = allSlots.where((t) => t.level == EducationLevel.bachelors).toList();
    final interSlots = allSlots.where((t) => t.level == EducationLevel.intermediate).toList();
    final singleLevel = _level != null;
    final filteredSlots = (singleLevel ? allSlots.where((t) => t.level == _level) : allSlots).toList();


    if (filteredSlots.isEmpty) {
      return _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentCyan,
          text: 'No time slots configured.');
    }

    // room -> timeSlotId -> List<Assignment>
    // For elective entries, dedupe per (room, slot) so each entry appears once.
    final roomById = {for (final r in dataVm.rooms) r.id: r.name};
    final Map<String, Map<String, Set<String>>> seenEntryPerRoomSlot = {};
    final Map<String, Map<String, List<Assignment>>> byTeacherSlot = {};
    for (final a in source.where((x) =>
        x.hasRoom &&
        roomById.containsKey(x.roomId) &&
        (_level == null || x.classModel.level == _level))) {
      final roomId = a.roomId!;
      final slotId = a.timeSlotId;
      if (a.id.startsWith('elec_')) {
        final lastUs = a.id.lastIndexOf('_');
        final entryKey = lastUs > 0 ? a.id.substring(0, lastUs) : a.id;
        final seen = seenEntryPerRoomSlot
            .putIfAbsent(roomId, () => {})
            .putIfAbsent(slotId, () => {});
        if (!seen.add(entryKey)) continue;
      }
      byTeacherSlot
          .putIfAbsent(roomId, () => {})
          .putIfAbsent(slotId, () => [])
          .add(a);
    }
    if (byTeacherSlot.isEmpty) return _emptyState(ctx, false);
    // Ascending order — numeric room names sort by value (so "9" comes
    // before "11"), any legacy non-numeric names fall back to A-Z after.
    var teachers = byTeacherSlot.keys.toList()..sort((a, b) {
      final an = int.tryParse(roomById[a] ?? '');
      final bn = int.tryParse(roomById[b] ?? '');
      if (an != null && bn != null) return an.compareTo(bn);
      if (an != null) return -1;
      if (bn != null) return 1;
      return (roomById[a] ?? '').compareTo(roomById[b] ?? '');
    });

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      teachers = teachers.where((t) => (roomById[t] ?? '').toLowerCase().contains(q)).toList();
    }
    if (teachers.isEmpty) return _noResults(ctx);

    // â”€â”€ Pre-compute clash pairs: (roomId, slotId, day) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // A cell is "clashing" if the teacher has another assignment on the same day
    // whose time slot overlaps in real clock time (even different slotIds).
    final clashKeys = <String>{}; // key = "roomId||slotId||day"
    final allSourceList = source.toList();
    for (int i = 0; i < allSourceList.length; i++) {
      final a = allSourceList[i];
      final slotA = allSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      for (int j = i + 1; j < allSourceList.length; j++) {
        final b = allSourceList[j];
        if (a.roomId == null || a.roomId != b.roomId) continue;
        final slotB = allSlots.where((t) => t.id == b.timeSlotId).firstOrNull;
        bool overlap = a.timeSlotId == b.timeSlotId;
        if (!overlap && slotA != null && slotB != null) {
          final aS = _parseMin(slotA.startTime), aE = _parseMin(slotA.endTime);
          final bS = _parseMin(slotB.startTime), bE = _parseMin(slotB.endTime);
          overlap = aS < bE && bS < aE;
        }
        if (!overlap) continue;
        final shared = a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
        if (shared.isEmpty) continue;

        // Ignore legitimate combined courses
        if (a.course.id == b.course.id) {
          final isCombined = dataVm.combinedRules.any((r) => 
              r.courseId == a.course.id &&
              r.classIds.contains(a.classModel.id) &&
              r.classIds.contains(b.classModel.id));
          if (isCombined) continue;
        }

        // Ignore if either assignment's class is in an elective group at that slot
        // (elective groups are intentional splits — teacher is only teaching their section)
        bool slotOverlap(String idA, String idB) {
          if (idA == idB) return true;
          final sA = allSlots.where((t) => t.id == idA).firstOrNull;
          final sB = allSlots.where((t) => t.id == idB).firstOrNull;
          if (sA == null || sB == null) return false;
          return _parseMin(sA.startTime) < _parseMin(sB.endTime) &&
              _parseMin(sB.startTime) < _parseMin(sA.endTime);
        }
        final aInElective = dataVm.electiveGroups.any((eg) =>
            slotOverlap(eg.timeSlotId, a.timeSlotId) &&
            eg.classIds.contains(a.classModel.id));
        final bInElective = dataVm.electiveGroups.any((eg) =>
            slotOverlap(eg.timeSlotId, b.timeSlotId) &&
            eg.classIds.contains(b.classModel.id));
        if (aInElective || bInElective) continue;

        for (final day in shared) {
          clashKeys.add('${a.roomId!}||${a.timeSlotId}||$day');
          clashKeys.add('${b.teacher.name}||${b.timeSlotId}||$day');
        }
      }
    }
    bool isCellClashing(String roomId, String tsId) =>
        clashKeys.any((k) => k.startsWith('$roomId||$tsId||'));

    return LayoutBuilder(builder: (ctx2, constraints) {
      final avail   = constraints.maxWidth;
      final rowLblW = avail < 420 ? 100.0 : avail < 600 ? 130.0 : 190.0;
      const double pxPerMin = 4.0;

      int parseMin(String t) => _parseMin(t);
      final allStarts = filteredSlots.map((t) => parseMin(t.startTime));
      final allEnds   = filteredSlots.map((t) => parseMin(t.endTime));
      final globalStart = allStarts.reduce((a, b) => a < b ? a : b);
      final globalEnd   = allEnds.reduce((a, b) => a > b ? a : b);
      double slotW(ts)      => math.max(0.0, (parseMin(ts.endTime) - parseMin(ts.startTime)) * pxPerMin);
      double slotOffset(ts) => math.max(0.0, (parseMin(ts.startTime) - globalStart) * pxPerMin);
      final timelineW       = math.max(0.0, (globalEnd - globalStart) * pxPerMin);

      // Ã¢â€â‚¬Ã¢â€â‚¬ period header cell Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      Widget periodHeader(ts, Color accent) => SizedBox(width: slotW(ts), child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(ts.shortLabel, style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w700, fontSize: 10, color: accent),
              textAlign: TextAlign.center),
          Text('${ts.startTime}-${ts.endTime}', style: GoogleFonts.plusJakartaSans(
              fontSize: 7, color: ctx._tm), textAlign: TextAlign.center),
          if (ts.hasFridayOverride)
            Text('Fri ${ts.fridayLabel}', style: GoogleFonts.plusJakartaSans(
                fontSize: 7, color: AppTheme.accentAmber), textAlign: TextAlign.center),
          if (settingsVm.fridayShortDay && ts.period > settingsVm.fridayMaxPeriod)
            Container(margin: const EdgeInsets.only(top: 2), padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: const Color(0xFFEF4444).withValues(alpha: .12), borderRadius: BorderRadius.circular(4)), child: Text('Fri off', style: GoogleFonts.plusJakartaSans(fontSize: 6, fontWeight: FontWeight.w800, color: const Color(0xFFEF4444)))),
        ]),
      ));
      // Ã¢â€â‚¬Ã¢â€â‚¬ assignment cell for teacher view Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      Widget rCell(ts, List<Assignment> aList, {bool clashing = false}) {
        final w = slotW(ts);
        if (aList.isEmpty) {
          return SizedBox(width: w, height: 72,
              child: Center(child: Text('-', style: TextStyle(
                  color: ctx._dk ? const Color(0xFF2A3A55) : const Color(0xFFCBD5E1),
                  fontSize: 12))));
        }

        // Group by courseId (merges combined classes for the same course)
        final Map<String, List<Assignment>> grouped = {};
        for (final a in aList) {
          grouped.putIfAbsent(a.course.id, () => []).add(a);
        }


        return SizedBox(width: w, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: grouped.values.map((group) {
            final a          = group.first;
            final isBach     = a.classModel.level == EducationLevel.bachelors;
            final isElective = a.id.startsWith('elec_');
            final effectiveClash = clashing;
            final col      = effectiveClash ? AppTheme.error
                : isElective ? AppTheme.accentAmber
                : (isBach ? AppTheme.accentCyan : AppTheme.accentViolet);
            final allDays  = group.expand((x) => x.occupiedSlots).toSet().toList()..sort();
            return Container(
              margin: const EdgeInsets.all(3),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: col.withValues(alpha: effectiveClash ? .15 : .1),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: col.withValues(alpha: effectiveClash ? .7 : .3),
                      width: effectiveClash ? 1.5 : 1)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Course name row — with clash icon if clashing
                if (effectiveClash) Row(children: [
                  Icon(Icons.warning_amber_rounded, color: col, size: 9),
                  const SizedBox(width: 2),
                  Expanded(child: Text(a.course.name, style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: col, fontSize: 10),
                      overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]) else Text(a.course.name, style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: col, fontSize: 10),
                    overflow: TextOverflow.ellipsis, maxLines: 1),
                const SizedBox(height: 2),
                // Secondary info: class names (electives list all attending classes)
                Builder(builder: (_) {
                  String teachers = group.map((x) => x.teacher.name).toSet().join(', ');
                  String label = teachers;
                  if (isElective) {
                    label = teachers;
                  }
                  return Text(label, style: GoogleFonts.plusJakartaSans(
                      fontSize: 8, color: isElective ? AppTheme.accentAmber : ctx._ts,
                      fontWeight: isElective ? FontWeight.w700 : FontWeight.w400),
                      overflow: TextOverflow.ellipsis, maxLines: 2);
                }),
                // Days row — same icon + format as class-wise
                if (formatDaysLabel(allDays) != null) Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 7, color: effectiveClash ? col : ctx._tm),
                  const SizedBox(width: 2),
                  Flexible(child: Text('Days: ${formatDaysLabel(allDays)}',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 8, fontWeight: FontWeight.w700,
                          color: effectiveClash ? col : ctx._tm),
                      overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]),
                if (true) ...[
                  Builder(builder: (_) {
                    String classes = group.map((x) => x.classModel.shortCode).toSet().join(', ');
                    if (isElective) {
                      final parts = a.id.split('_');
                      if (parts.length >= 3) {
                        final egId = parts[1];
                        final eg = dataVm.electiveGroups.where((g) => g.id == egId).firstOrNull;
                        if (eg != null) {
                          classes = eg.classIds
                              .map((cid) => dataVm.classes.where((c) => c.id == cid).firstOrNull?.shortCode ?? '?')
                              .join(', ');
                        }
                      }
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 1),
                        Row(children: [
                          Icon(Icons.group_rounded,
                              size: 7, color: effectiveClash ? col : ctx._tm),
                          const SizedBox(width: 2),
                          Flexible(child: Text(classes,
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 8, fontWeight: FontWeight.w700,
                                  color: effectiveClash ? col : ctx._tm),
                              overflow: TextOverflow.ellipsis, maxLines: 1)),
                        ]),
                      ]
                    );
                  }),
                ],
              ]),
            );
          }).toList(),
        ));
      }

      // Ã¢â€â‚¬Ã¢â€â‚¬ Build a proportional-width row of slot cells Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      List<Widget> slotRow(List slots, Map<String, List<Assignment>> pMap, String roomId) {
        if (slots.isEmpty) return [SizedBox(width: timelineW)];
        final lead  = slotOffset(slots.first);
        final trail = timelineW - lead - slots.fold(0.0, (s, t) => s + slotW(t));
        return [
          if (lead > 0)  SizedBox(width: lead),
          ...slots.map((ts) => rCell(ts, pMap[ts.id] ?? [],
              clashing: isCellClashing(roomId, ts.id as String))),
          if (trail > 0) SizedBox(width: trail),
        ];
      }

      List<Widget> headerRow(List slots, Color accent) {
        if (slots.isEmpty) return [SizedBox(width: timelineW)];
        final lead  = slotOffset(slots.first);
        final trail = timelineW - lead - slots.fold(0.0, (s, t) => s + slotW(t));
        return [
          if (lead > 0)  SizedBox(width: lead),
          ...slots.map((ts) => periodHeader(ts, accent)),
          if (trail > 0) SizedBox(width: trail),
        ];
      }

      return Container(
        decoration: ctx.glassC(r: 20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicWidth(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Ã¢â€â‚¬Ã¢â€â‚¬ HEADERS Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
                if (singleLevel) ...[
                  Container(color: ctx._hd, child: Row(children: [
                    SizedBox(width: rowLblW, child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('Room', style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, fontSize: 11, color: ctx._ts)))),
                    ...headerRow(filteredSlots,
                        _level == EducationLevel.bachelors ? AppTheme.accentCyan : AppTheme.accentViolet),
                  ])),
                ] else ...[
                  // Row 1: Bachelors (cyan)
                  if (bachSlots.isNotEmpty)
                    Container(color: AppTheme.accentCyan.withValues(alpha: .07), child: Row(children: [
                      SizedBox(width: rowLblW, child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Text('Bach', style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800, fontSize: 10, color: AppTheme.accentCyan)))),
                      ...headerRow(bachSlots, AppTheme.accentCyan),
                    ])),
                  // Row 2: Intermediate (violet)
                  if (interSlots.isNotEmpty)
                    Container(color: AppTheme.accentViolet.withValues(alpha: .07), child: Row(children: [
                      SizedBox(width: rowLblW, child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Text('Inter', style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800, fontSize: 10, color: AppTheme.accentViolet)))),
                      ...headerRow(interSlots, AppTheme.accentViolet),
                    ])),
                ],
                Divider(color: ctx._dv, height: 1),

                // Ã¢â€â‚¬Ã¢â€â‚¬ TEACHER ROWS Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
                ...teachers.map((tName) {
                  final slotMap = byTeacherSlot[tName]!;
                  final realRoomName = roomById[tName] ?? tName;

                  // Detect which levels this teacher actually teaches
                  final hasBach  = bachSlots.any((ts)  => slotMap.containsKey(ts.id));
                  final hasInter = interSlots.any((ts) => slotMap.containsKey(ts.id));

                  // Teacher label widget
                  Widget labelWidget = Container(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                    child: Row(children: [
                      Container(width: 26, height: 26,
                          decoration: BoxDecoration(
                              gradient: AppTheme.violetGradient,
                              borderRadius: BorderRadius.circular(8)),
                          child: Center(child: Text(
                              realRoomName.isNotEmpty ? realRoomName[0].toUpperCase() : '?',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white, fontSize: 11)))),
                      const SizedBox(width: 7),
                      Flexible(child: Text(realRoomName,
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w600,
                              color: ctx._tp, fontSize: 11),
                          overflow: TextOverflow.ellipsis)),
                    ]),
                  );

                  // Placeholder (same width as label, no content) for continuation rows
                  final labelGap = SizedBox(width: rowLblW);

                  if (singleLevel) {
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: rowLblW, child: labelWidget),
                        ...slotRow(filteredSlots, slotMap, tName),
                      ]),
                      Divider(color: ctx._dv, height: 1),
                    ]);
                  }

                  // All Levels: only show sub-rows for levels this teacher teaches.
                  // A teacher with only Bach assignments Ã¢â€ â€™ 1 Bach row (no empty Inter row).
                  // A teacher with both Ã¢â€ â€™ Bach row on top, Inter row below.
                  // This matches ClassÃƒâ€”Period compactness exactly.
                  final showBach  = bachSlots.isNotEmpty  && (hasBach  || !hasInter);
                  final showInter = interSlots.isNotEmpty && (hasInter || !hasBach);

                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    if (showBach)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: rowLblW, child: labelWidget),
                        ...slotRow(bachSlots, slotMap, tName),
                      ]),
                    if (showBach && showInter)
                      Divider(color: ctx._dv.withValues(alpha: .3), height: 0.5),
                    if (showInter)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // Show label on inter row only if no bach row above it
                        showBach ? labelGap
                            : SizedBox(width: rowLblW, child: labelWidget),
                        ...slotRow(interSlots, slotMap, tName),
                      ]),
                    Divider(color: ctx._dv, height: 1),
                  ]);
                }),
              ],
            )),
          ),
        ),
      );
    });
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬ VIEW 2: Teacher Ãƒâ€” Period (mirrors ClassÃƒâ€”Period layout) Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  Widget _teacherDayMatrix(
      BuildContext ctx, DataEntryViewModel dataVm, AllocatorViewModel allocVm, SettingsViewModel settingsVm) {
    // Include elective entries so elective teachers appear in their slot.
    // One elective entry teaches multiple classes SIMULTANEOUSLY — dedupe by
    // (group, entry) so the teacher's cell shows the lecture once, not per class.
    // Build source: keep ALL per-class assignments so level filter works correctly.
    // Dedup will happen per teacher+slot combination below.
    final source = List<Assignment>.from(dataVm.combinedAssignments);
    if (source.isEmpty && dataVm.electiveGroups.isEmpty) return _emptyState(ctx, false);

    // Same slot setup as classPeriodMatrix
    final allSlots = dataVm.timeSlots.toList()..sort((a, b) {
      final lc = a.level.index.compareTo(b.level.index);
      return lc != 0 ? lc : a.period.compareTo(b.period);
    });
    // Show ALL configured slots
    final bachSlots  = allSlots.where((t) => t.level == EducationLevel.bachelors).toList();
    final interSlots = allSlots.where((t) => t.level == EducationLevel.intermediate).toList();
    final singleLevel = _level != null;
    final filteredSlots = (singleLevel ? allSlots.where((t) => t.level == _level) : allSlots).toList();


    if (filteredSlots.isEmpty) {
      return _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentCyan,
          text: 'No time slots configured.');
    }

    // teacher -> timeSlotId -> List<Assignment>
    // For elective entries, dedupe per (teacher, slot) so each entry appears once.
    final roomById = {for (final r in dataVm.rooms) r.id: r.name};
    final Map<String, Map<String, Set<String>>> seenEntryPerTeacherSlot = {};
    final Map<String, Map<String, List<Assignment>>> byTeacherSlot = {};
    for (final a in source.where((x) => _level == null || x.classModel.level == _level)) {
      final tName = a.teacher.name;
      final slotId = a.timeSlotId;
      if (a.id.startsWith('elec_')) {
        final lastUs = a.id.lastIndexOf('_');
        final entryKey = lastUs > 0 ? a.id.substring(0, lastUs) : a.id;
        final seen = seenEntryPerTeacherSlot
            .putIfAbsent(tName, () => {})
            .putIfAbsent(slotId, () => {});
        if (!seen.add(entryKey)) continue;
      }
      byTeacherSlot
          .putIfAbsent(tName, () => {})
          .putIfAbsent(slotId, () => [])
          .add(a);
    }
    if (byTeacherSlot.isEmpty) return _emptyState(ctx, false);
    var teachers = byTeacherSlot.keys.toList()..sort();

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      teachers = teachers.where((t) => t.toLowerCase().contains(q)).toList();
    }
    if (teachers.isEmpty) return _noResults(ctx);

    // â”€â”€ Pre-compute clash pairs: (teacherName, slotId, day) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // A cell is "clashing" if the teacher has another assignment on the same day
    // whose time slot overlaps in real clock time (even different slotIds).
    final clashKeys = <String>{}; // key = "teacherName||slotId||day"
    final allSourceList = source.toList();
    for (int i = 0; i < allSourceList.length; i++) {
      final a = allSourceList[i];
      final slotA = allSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      for (int j = i + 1; j < allSourceList.length; j++) {
        final b = allSourceList[j];
        if (a.teacher.id != b.teacher.id) continue;
        final slotB = allSlots.where((t) => t.id == b.timeSlotId).firstOrNull;
        bool overlap = a.timeSlotId == b.timeSlotId;
        if (!overlap && slotA != null && slotB != null) {
          final aS = _parseMin(slotA.startTime), aE = _parseMin(slotA.endTime);
          final bS = _parseMin(slotB.startTime), bE = _parseMin(slotB.endTime);
          overlap = aS < bE && bS < aE;
        }
        if (!overlap) continue;
        final shared = a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
        if (shared.isEmpty) continue;

        // Ignore legitimate combined courses
        if (a.course.id == b.course.id) {
          final isCombined = dataVm.combinedRules.any((r) => 
              r.courseId == a.course.id &&
              r.classIds.contains(a.classModel.id) &&
              r.classIds.contains(b.classModel.id));
          if (isCombined) continue;
        }

        // Ignore if either assignment's class is in an elective group at that slot
        // (elective groups are intentional splits — teacher is only teaching their section)
        bool slotOverlap(String idA, String idB) {
          if (idA == idB) return true;
          final sA = allSlots.where((t) => t.id == idA).firstOrNull;
          final sB = allSlots.where((t) => t.id == idB).firstOrNull;
          if (sA == null || sB == null) return false;
          return _parseMin(sA.startTime) < _parseMin(sB.endTime) &&
              _parseMin(sB.startTime) < _parseMin(sA.endTime);
        }
        final aInElective = dataVm.electiveGroups.any((eg) =>
            slotOverlap(eg.timeSlotId, a.timeSlotId) &&
            eg.classIds.contains(a.classModel.id));
        final bInElective = dataVm.electiveGroups.any((eg) =>
            slotOverlap(eg.timeSlotId, b.timeSlotId) &&
            eg.classIds.contains(b.classModel.id));
        if (aInElective || bInElective) continue;

        for (final day in shared) {
          clashKeys.add('${a.teacher.name}||${a.timeSlotId}||$day');
          clashKeys.add('${b.teacher.name}||${b.timeSlotId}||$day');
        }
      }
    }
    bool isCellClashing(String teacherName, String tsId) =>
        clashKeys.any((k) => k.startsWith('$teacherName||$tsId||'));

    return LayoutBuilder(builder: (ctx2, constraints) {
      final avail   = constraints.maxWidth;
      final rowLblW = avail < 420 ? 100.0 : avail < 600 ? 130.0 : 190.0;
      const double pxPerMin = 4.0;

      int parseMin(String t) => _parseMin(t);
      final allStarts = filteredSlots.map((t) => parseMin(t.startTime));
      final allEnds   = filteredSlots.map((t) => parseMin(t.endTime));
      final globalStart = allStarts.reduce((a, b) => a < b ? a : b);
      final globalEnd   = allEnds.reduce((a, b) => a > b ? a : b);
      double slotW(ts)      => math.max(0.0, (parseMin(ts.endTime) - parseMin(ts.startTime)) * pxPerMin);
      double slotOffset(ts) => math.max(0.0, (parseMin(ts.startTime) - globalStart) * pxPerMin);
      final timelineW       = math.max(0.0, (globalEnd - globalStart) * pxPerMin);

      // Ã¢â€â‚¬Ã¢â€â‚¬ period header cell Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      Widget periodHeader(ts, Color accent) => SizedBox(width: slotW(ts), child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(ts.shortLabel, style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w700, fontSize: 10, color: accent),
              textAlign: TextAlign.center),
          Text('${ts.startTime}-${ts.endTime}', style: GoogleFonts.plusJakartaSans(
              fontSize: 7, color: ctx._tm), textAlign: TextAlign.center),
          if (ts.hasFridayOverride)
            Text('Fri ${ts.fridayLabel}', style: GoogleFonts.plusJakartaSans(
                fontSize: 7, color: AppTheme.accentAmber), textAlign: TextAlign.center),
          if (settingsVm.fridayShortDay && ts.period > settingsVm.fridayMaxPeriod)
            Container(margin: const EdgeInsets.only(top: 2), padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: const Color(0xFFEF4444).withValues(alpha: .12), borderRadius: BorderRadius.circular(4)), child: Text('Fri off', style: GoogleFonts.plusJakartaSans(fontSize: 6, fontWeight: FontWeight.w800, color: const Color(0xFFEF4444)))),
        ]),
      ));
      // Ã¢â€â‚¬Ã¢â€â‚¬ assignment cell for teacher view Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      Widget tCell(ts, List<Assignment> aList, {bool clashing = false}) {
        final w = slotW(ts);
        if (aList.isEmpty) {
          return SizedBox(width: w, height: 72,
              child: Center(child: Text('-', style: TextStyle(
                  color: ctx._dk ? const Color(0xFF2A3A55) : const Color(0xFFCBD5E1),
                  fontSize: 12))));
        }


        // Group by courseId (merges combined classes for the same course)
        final Map<String, List<Assignment>> grouped = {};
        for (final a in aList) {
          grouped.putIfAbsent(a.course.id, () => []).add(a);
        }


        return SizedBox(width: w, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: grouped.values.map((group) {
            final a          = group.first;
            final isBach     = a.classModel.level == EducationLevel.bachelors;
            final isElective = a.id.startsWith('elec_');
            final effectiveClash = clashing;
            final col      = effectiveClash ? AppTheme.error
                : isElective ? AppTheme.accentAmber
                : (isBach ? AppTheme.accentCyan : AppTheme.accentViolet);
            final allDays  = group.expand((x) => x.occupiedSlots).toSet().toList()..sort();
            return Container(
              margin: const EdgeInsets.all(3),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: col.withValues(alpha: effectiveClash ? .15 : .1),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: col.withValues(alpha: effectiveClash ? .7 : .3),
                      width: effectiveClash ? 1.5 : 1)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Course name row — with clash icon if clashing
                if (effectiveClash) Row(children: [
                  Icon(Icons.warning_amber_rounded, color: col, size: 9),
                  const SizedBox(width: 2),
                  Expanded(child: Text(a.course.name, style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: col, fontSize: 10),
                      overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]) else Text(a.course.name, style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: col, fontSize: 10),
                    overflow: TextOverflow.ellipsis, maxLines: 1),
                const SizedBox(height: 2),
                // Secondary info: class names (electives list all attending classes)
                Builder(builder: (_) {
                  String label = group.map((x) => x.classModel.shortCode).toSet().join(', ');
                  if (isElective) {
                    // id: elec_<groupId>_<entryId>_<classId> — list all attending classes
                    final parts = a.id.split('_');
                    if (parts.length >= 3) {
                      final egId = parts[1];
                      final eg = dataVm.electiveGroups.where((g) => g.id == egId).firstOrNull;
                      if (eg != null) {
                        label = eg.classIds
                            .map((cid) => dataVm.classes.where((c) => c.id == cid).firstOrNull?.shortCode ?? '?')
                            .join(', ');
                      }
                    }
                  }
                  return Text(label, style: GoogleFonts.plusJakartaSans(
                      fontSize: 8, color: isElective ? AppTheme.accentAmber : ctx._ts,
                      fontWeight: isElective ? FontWeight.w700 : FontWeight.w400),
                      overflow: TextOverflow.ellipsis, maxLines: 2);
                }),
                // Days row — same icon + format as class-wise
                if (formatDaysLabel(allDays) != null) Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 7, color: effectiveClash ? col : ctx._tm),
                  const SizedBox(width: 2),
                  Flexible(child: Text('Days: ${formatDaysLabel(allDays)}',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 8, fontWeight: FontWeight.w700,
                          color: effectiveClash ? col : ctx._tm),
                      overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]),
                if (a.hasRoom) ...[
                  const SizedBox(height: 1),
                  Row(children: [
                    Icon(Icons.meeting_room_rounded,
                        size: 7, color: effectiveClash ? col : ctx._tm),
                    const SizedBox(width: 2),
                    Flexible(child: Text(roomById[a.roomId] ?? 'Unknown',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 8, fontWeight: FontWeight.w700,
                            color: effectiveClash ? col : ctx._tm),
                        overflow: TextOverflow.ellipsis, maxLines: 1)),
                  ]),
                ],
              ]),
            );
          }).toList(),
        ));
      }

      // Ã¢â€â‚¬Ã¢â€â‚¬ Build a proportional-width row of slot cells Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
      List<Widget> slotRow(List slots, Map<String, List<Assignment>> pMap, String teacherName) {
        if (slots.isEmpty) return [SizedBox(width: timelineW)];
        final lead  = slotOffset(slots.first);
        final trail = timelineW - lead - slots.fold(0.0, (s, t) => s + slotW(t));
        return [
          if (lead > 0)  SizedBox(width: lead),
          ...slots.map((ts) => tCell(ts, pMap[ts.id] ?? [],
              clashing: isCellClashing(teacherName, ts.id as String))),
          if (trail > 0) SizedBox(width: trail),
        ];
      }

      List<Widget> headerRow(List slots, Color accent) {
        if (slots.isEmpty) return [SizedBox(width: timelineW)];
        final lead  = slotOffset(slots.first);
        final trail = timelineW - lead - slots.fold(0.0, (s, t) => s + slotW(t));
        return [
          if (lead > 0)  SizedBox(width: lead),
          ...slots.map((ts) => periodHeader(ts, accent)),
          if (trail > 0) SizedBox(width: trail),
        ];
      }

      return Container(
        decoration: ctx.glassC(r: 20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicWidth(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Ã¢â€â‚¬Ã¢â€â‚¬ HEADERS Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
                if (singleLevel) ...[
                  Container(color: ctx._hd, child: Row(children: [
                    SizedBox(width: rowLblW, child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('Teacher', style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, fontSize: 11, color: ctx._ts)))),
                    ...headerRow(filteredSlots,
                        _level == EducationLevel.bachelors ? AppTheme.accentCyan : AppTheme.accentViolet),
                  ])),
                ] else ...[
                  // Row 1: Bachelors (cyan)
                  if (bachSlots.isNotEmpty)
                    Container(color: AppTheme.accentCyan.withValues(alpha: .07), child: Row(children: [
                      SizedBox(width: rowLblW, child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Text('Bach', style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800, fontSize: 10, color: AppTheme.accentCyan)))),
                      ...headerRow(bachSlots, AppTheme.accentCyan),
                    ])),
                  // Row 2: Intermediate (violet)
                  if (interSlots.isNotEmpty)
                    Container(color: AppTheme.accentViolet.withValues(alpha: .07), child: Row(children: [
                      SizedBox(width: rowLblW, child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Text('Inter', style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800, fontSize: 10, color: AppTheme.accentViolet)))),
                      ...headerRow(interSlots, AppTheme.accentViolet),
                    ])),
                ],
                Divider(color: ctx._dv, height: 1),

                // Ã¢â€â‚¬Ã¢â€â‚¬ TEACHER ROWS Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
                ...teachers.map((tName) {
                  final slotMap = byTeacherSlot[tName]!;
                  final realRoomName = roomById[tName] ?? tName;

                  // Detect which levels this teacher actually teaches
                  final hasBach  = bachSlots.any((ts)  => slotMap.containsKey(ts.id));
                  final hasInter = interSlots.any((ts) => slotMap.containsKey(ts.id));

                  // Teacher label widget
                  Widget labelWidget = Container(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                    child: Row(children: [
                      Container(width: 26, height: 26,
                          decoration: BoxDecoration(
                              gradient: AppTheme.violetGradient,
                              borderRadius: BorderRadius.circular(8)),
                          child: Center(child: Text(
                              realRoomName.isNotEmpty ? realRoomName[0].toUpperCase() : '?',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white, fontSize: 11)))),
                      const SizedBox(width: 7),
                      Flexible(child: Text(realRoomName,
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w600,
                              color: ctx._tp, fontSize: 11),
                          overflow: TextOverflow.ellipsis)),
                    ]),
                  );

                  // Placeholder (same width as label, no content) for continuation rows
                  final labelGap = SizedBox(width: rowLblW);

                  if (singleLevel) {
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: rowLblW, child: labelWidget),
                        ...slotRow(filteredSlots, slotMap, tName),
                      ]),
                      Divider(color: ctx._dv, height: 1),
                    ]);
                  }

                  // All Levels: only show sub-rows for levels this teacher teaches.
                  // A teacher with only Bach assignments Ã¢â€ â€™ 1 Bach row (no empty Inter row).
                  // A teacher with both Ã¢â€ â€™ Bach row on top, Inter row below.
                  // This matches ClassÃƒâ€”Period compactness exactly.
                  final showBach  = bachSlots.isNotEmpty  && (hasBach  || !hasInter);
                  final showInter = interSlots.isNotEmpty && (hasInter || !hasBach);

                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    if (showBach)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: rowLblW, child: labelWidget),
                        ...slotRow(bachSlots, slotMap, tName),
                      ]),
                    if (showBach && showInter)
                      Divider(color: ctx._dv.withValues(alpha: .3), height: 0.5),
                    if (showInter)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // Show label on inter row only if no bach row above it
                        showBach ? labelGap
                            : SizedBox(width: rowLblW, child: labelWidget),
                        ...slotRow(interSlots, slotMap, tName),
                      ]),
                    Divider(color: ctx._dv, height: 1),
                  ]);
                }),
              ],
            )),
          ),
        ),
      );
    });
  }

} // end _MatrixScreenState



// Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
// View Toggle Tab
// Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
class _ViewTab extends StatelessWidget {
  final IconData icon; final String label, sublabel;
  final bool selected; final Color color; final VoidCallback onTap;
  const _ViewTab({required this.icon, required this.label, required this.sublabel,
    required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final unselTs = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final unselTm = isDark ? AppTheme.textMuted     : AppTheme.lightTextMut;
    return Expanded(child: GestureDetector(onTap: onTap,
        child: AnimatedContainer(duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
          decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: .15) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: selected ? Border.all(color: color.withValues(alpha: .4)) : null),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: selected ? color : (isDark ? AppTheme.textMuted : AppTheme.lightTextMut),
                size: 18),
            const SizedBox(width: 8),
            Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: selected ? color : unselTs),
                  overflow: TextOverflow.ellipsis),
              if (sublabel.isNotEmpty)
                Text(sublabel, style: GoogleFonts.plusJakartaSans(
                    fontSize: 11, color: unselTm),
                    overflow: TextOverflow.ellipsis),
            ])),
          ]),
        )));
  }
}

// Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
// Info Box
// Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
class _InfoBox extends StatelessWidget {
  final IconData icon; final Color color; final String text;
  const _InfoBox({required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: .25))),
      child: Row(children: [
        Icon(icon, color: color, size: 18), const SizedBox(width: 10),
        Expanded(child: Text(text, style: GoogleFonts.plusJakartaSans(
            color: color, fontWeight: FontWeight.w600, fontSize: 13))),
      ]));
}

// ════════════════════════════════════════════════════════════════════════════
// Move Course Dialog — relocate one card to a different period. Pure move:
// teacher, days, room and credit hours are untouched (see
// DataEntryViewModel.moveAssignmentPeriod).
// ════════════════════════════════════════════════════════════════════════════
class _MoveCourseDialog extends StatefulWidget {
  final DataEntryViewModel dataVm;
  const _MoveCourseDialog({required this.dataVm});

  @override
  State<_MoveCourseDialog> createState() => _MoveCourseDialogState();
}

class _MoveCourseDialogState extends State<_MoveCourseDialog> {
  String? _classId;
  String? _assignmentId;
  String? _targetSlotId;
  String? _error;

  DataEntryViewModel get _vm => widget.dataVm;

  String _classLabel(ClassModel c) {
    final prog = _vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? '';
    return prog.isEmpty ? c.name : '$prog-${c.name}';
  }

  List<Assignment> get _assignmentsForClass => _classId == null
      ? const []
      : (_vm.assignments.where((a) => a.classModel.id == _classId).toList()
        ..sort((a, b) => a.course.name.compareTo(b.course.name)));

  Assignment? get _selectedAssignment => _assignmentId == null
      ? null
      : _vm.assignments.where((a) => a.id == _assignmentId).firstOrNull;

  List<TimeSlot> get _candidateSlots {
    final a = _selectedAssignment;
    if (a == null) return const [];
    return _vm.timeSlots
        .where((t) => t.level == a.classModel.level && t.id != a.timeSlotId)
        .toList()
      ..sort((x, y) => x.period.compareTo(y.period));
  }

  void _apply() {
    final a = _selectedAssignment;
    final slotId = _targetSlotId;
    if (a == null || slotId == null) return;
    setState(() => _error = null);
    final err = _vm.moveAssignmentPeriod(a.id, slotId);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(
            'Moved "${a.course.name}" (${a.classModel.shortCode}) to '
            '${_vm.timeSlots.where((t) => t.id == slotId).firstOrNull?.shortLabel ?? slotId}.',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white))),
      ]),
      backgroundColor: AppTheme.accentTeal,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tp = isDark ? Colors.white : const Color(0xFF0F172A);
    final ts = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final cd = isDark ? const Color(0xFF1E293B) : Colors.white;
    final bd = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    const cyan = AppTheme.accentCyan;

    final classes = _vm.classes.toList()
      ..sort((a, b) => _classLabel(a).compareTo(_classLabel(b)));

    InputDecoration dec(String label) => InputDecoration(
          labelText: label,
          labelStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts),
          filled: true,
          fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bd)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        );

    return Dialog(
      backgroundColor: cd,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppTheme.accentCyan, Color(0xFF0891B2)]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.open_with_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Move Course', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 18, color: tp)),
                Text('Relocate one card to a different period — nothing else changes',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts)),
              ])),
              IconButton(icon: Icon(Icons.close_rounded, color: ts), onPressed: () => Navigator.of(context).pop()),
            ]),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              decoration: dec('Class'),
              initialValue: _classId,
              isExpanded: true,
              items: classes.map((c) => DropdownMenuItem(value: c.id,
                  child: Text(_classLabel(c), style: GoogleFonts.plusJakartaSans(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() { _classId = v; _assignmentId = null; _targetSlotId = null; _error = null; }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              decoration: dec('Course'),
              initialValue: _assignmentId,
              isExpanded: true,
              items: _assignmentsForClass.map((a) => DropdownMenuItem(value: a.id,
                  child: Text('${a.course.name} — currently ${a.slotLabel}',
                      style: GoogleFonts.plusJakartaSans(fontSize: 13), overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() { _assignmentId = v; _targetSlotId = null; _error = null; }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              decoration: dec('Move to period'),
              initialValue: _targetSlotId,
              isExpanded: true,
              items: _candidateSlots.map((t) => DropdownMenuItem(value: t.id,
                  child: Text(t.shortLabel, style: GoogleFonts.plusJakartaSans(fontSize: 13)))).toList(),
              onChanged: _selectedAssignment == null ? null : (v) => setState(() { _targetSlotId = v; _error = null; }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded, size: 16, color: AppTheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppTheme.error))),
                ]),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_selectedAssignment != null && _targetSlotId != null) ? _apply : null,
                style: FilledButton.styleFrom(backgroundColor: cyan, padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: Text('Move', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Batch Teacher Transfer Dialog
// ════════════════════════════════════════════════════════════════════════════
class _TeacherTransferDialog extends StatefulWidget {
  final DataEntryViewModel dataVm;
  const _TeacherTransferDialog({required this.dataVm});

  @override
  State<_TeacherTransferDialog> createState() => _TeacherTransferDialogState();
}

class _TeacherTransferDialogState extends State<_TeacherTransferDialog> {
  // teacherId → replacement Teacher (null = not yet picked)
  final Map<String, Teacher?> _replacements = {};
  // teacherId → set of classIds of THEIRS selected to hand off. A teacher
  // only counts as "leaving" for a given class if that class's id is in
  // their set here — lets a user transfer just one class of a teacher's
  // load instead of all of it.
  final Map<String, Set<String>> _selectedClasses = {};
  bool _applying = false;

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // ── Swap mode ──────────────────────────────────────────────────────────
  bool _swapMode = false;
  String? _swapClassId;
  // Up to 2 picked assignment ids, in pick order (index 0 = "A", 1 = "B").
  final List<String> _swapSelected = [];
  bool _swapping = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  DataEntryViewModel get _vm => widget.dataVm;

  // "{program}-{class}" label, same convention as the matrix screen's chips.
  String _classLabel(ClassModel c) {
    final prog = _vm.programs.where((p) => p.id == c.programId).firstOrNull?.name ?? '';
    return prog.isEmpty ? c.name : '$prog-${c.name}';
  }

  // Every class this teacher currently teaches, via regular assignments or
  // elective entries — so a leaving teacher's row shows what can be handed off.
  List<ClassModel> _classesFor(String teacherId) {
    final classIds = <String>{};
    for (final a in _vm.assignments.where((a) => a.teacher.id == teacherId)) {
      classIds.add(a.classModel.id);
    }
    for (final g in _vm.electiveGroups.where(
        (g) => g.entries.any((e) => e.teacherId == teacherId))) {
      classIds.addAll(g.classIds);
    }
    final classes = classIds
        .map((id) => _vm.classes.where((c) => c.id == id).firstOrNull)
        .whereType<ClassModel>()
        .toList()
      ..sort((a, b) => _classLabel(a).compareTo(_classLabel(b)));
    return classes;
  }

  // How many regular assignments does this teacher have?
  int _assignmentCount(String teacherId) =>
      _vm.assignments.where((a) => a.teacher.id == teacherId).length;

  // How many elective entries?
  int _electiveCount(String teacherId) => _vm.electiveGroups
      .expand((g) => g.entries)
      .where((e) => e.teacherId == teacherId)
      .length;

  int _totalCount(String teacherId) =>
      _assignmentCount(teacherId) + _electiveCount(teacherId);

  // Teacher ids with at least one class actually selected for transfer.
  Iterable<String> get _activeTeacherIds =>
      _selectedClasses.entries.where((e) => e.value.isNotEmpty).map((e) => e.key);

  bool get _canApply =>
      _activeTeacherIds.isNotEmpty &&
      _activeTeacherIds.every((id) => _replacements[id] != null);

  void _apply() async {
    setState(() => _applying = true);
    // teacherId → {classId → newTeacher}
    final Map<String, Map<String, Teacher>> map = {};
    for (final oldId in _activeTeacherIds) {
      final newT = _replacements[oldId];
      if (newT == null) continue;
      map[oldId] = {for (final classId in _selectedClasses[oldId]!) classId: newT};
    }
    final activeCount = _activeTeacherIds.length;
    final count = _vm.replaceTeacherForClasses(map);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Text('$count assignment${count != 1 ? "s" : ""} updated across $activeCount teacher transfer${activeCount != 1 ? "s" : ""}.',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        ]),
        backgroundColor: AppTheme.accentTeal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  // ── Swap mode helpers ────────────────────────────────────────────────────

  // Regular (non-elective) assignments for the class picked in swap mode —
  // "same row" per the request: swapping is only offered within one class.
  List<Assignment> _swapAssignmentsForClass(String classId) {
    final list = _vm.assignments.where((a) => a.classModel.id == classId).toList()
      ..sort((a, b) => a.teacher.name.compareTo(b.teacher.name));
    return list;
  }

  Assignment? _swapAssignmentById(String id) =>
      _vm.assignments.where((a) => a.id == id).firstOrNull;

  // Live validation mirrored from DataEntryViewModel.swapAssignmentTeachers,
  // so the button can be disabled with an explanation before the user taps it.
  String? get _swapBlockedReason {
    if (_swapSelected.length != 2) return null;
    final a = _swapAssignmentById(_swapSelected[0]);
    final b = _swapAssignmentById(_swapSelected[1]);
    if (a == null || b == null) return 'Selected period no longer exists.';
    if (a.teacher.id == b.teacher.id) return 'Pick two different teachers.';
    if (a.course.creditHours != b.course.creditHours) {
      return 'Credit hours don\'t match (${a.course.creditHours}h vs ${b.course.creditHours}h) — swap needs equal credit hours.';
    }
    bool wouldClash(Assignment moving, Teacher incoming, String excludeId) {
      final movingKeys = moving.occupiedSlots
          .map((s) => '${incoming.id}__${s}__${moving.timeSlotId}')
          .toSet();
      final existingKeys = _vm.assignments
          .where((x) => x.id != excludeId && x.teacher.id == incoming.id)
          .expand((x) => x.teacherKeys)
          .toSet();
      return movingKeys.intersection(existingKeys).isNotEmpty;
    }
    if (wouldClash(a, b.teacher, b.id) || wouldClash(b, a.teacher, a.id)) {
      return 'This swap would double-book one of the teachers at that time.';
    }
    return null;
  }

  bool get _canSwap => _swapSelected.length == 2 && _swapBlockedReason == null;

  void _performSwap() {
    if (!_canSwap) return;
    setState(() => _swapping = true);
    final a = _swapAssignmentById(_swapSelected[0])!;
    final b = _swapAssignmentById(_swapSelected[1])!;
    final result = _vm.swapAssignmentTeachers(_swapSelected[0], _swapSelected[1]);
    if (!mounted) return;
    if (result == TeacherSwapResult.success) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Text('Swapped ${a.teacher.name} ↔ ${b.teacher.name}.',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        ]),
        backgroundColor: AppTheme.accentTeal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
      ));
    } else {
      setState(() => _swapping = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Swap failed — the underlying data changed. Please retry.',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tp = isDark ? Colors.white : const Color(0xFF0F172A);
    final ts = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final cd = isDark ? const Color(0xFF1E293B) : Colors.white;
    final bd = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    const orange = Color(0xFFF97316);

    final teachers = _vm.teachers.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final replacementCandidates = teachers; // all teachers can be replacements
    final filteredTeachers = _query.isEmpty
        ? teachers
        : teachers.where((t) =>
            t.name.toLowerCase().contains(_query.toLowerCase()) ||
            t.department.toLowerCase().contains(_query.toLowerCase())).toList();

    return Dialog(
      backgroundColor: cd,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ───────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 18),
              decoration: BoxDecoration(
                color: orange.withValues(alpha: .08),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(bottom: BorderSide(color: orange.withValues(alpha: .2))),
              ),
              child: Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFF97316), Color(0xFFEA580C)]),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: orange.withValues(alpha: .35), blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  child: const Icon(Icons.swap_horiz_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_swapMode ? 'Swap Teachers' : 'Manage Teacher Transfers', style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, fontSize: 18, color: tp)),
                  Text(_swapMode
                      ? 'Swap two teachers within the same class — no re-allocation needed'
                      : 'Mark leaving teachers and assign replacements — applied in one click',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts)),
                ]),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: ts),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),

            // ── Mode toggle ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: Row(children: [
                _modeTab('Transfer', !_swapMode, orange, () => setState(() => _swapMode = false)),
                const SizedBox(width: 8),
                _modeTab('Swap', _swapMode, orange, () => setState(() => _swapMode = true)),
              ]),
            ),

            if (!_swapMode) ...[
              // ── Instructions strip ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 4),
                child: Row(children: [
                  _stepChip('1', 'Check teachers leaving', orange),
                  const SizedBox(width: 12),
                  _stepChip('2', 'Pick their replacement', orange),
                  const SizedBox(width: 12),
                  _stepChip('3', 'Tap Apply All', orange),
                ]),
              ),

              // ── Search bar ───────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: _SearchBar(
                  controller: _searchCtrl,
                  query: _query,
                  isDark: isDark,
                  hint: 'Search teachers…',
                  onChanged: (v) => setState(() => _query = v),
                  onClear: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
              ),

              // ── Column headers ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
                child: Row(children: [
                  SizedBox(width: 36, child: Text('Leave', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: ts))),
                  const SizedBox(width: 8),
                  Expanded(flex: 3, child: Text('Transferred Teacher', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: ts))),
                  SizedBox(width: 70, child: Text('Slots', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: ts), textAlign: TextAlign.center)),
                  const SizedBox(width: 12),
                  Expanded(flex: 3, child: Text('Replacement Teacher', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: ts))),
                ]),
            ),

            // ── Divider ───────────────────────────────────────────────────
            Divider(height: 1, color: bd),

            // ── Teacher list ──────────────────────────────────────────────
            Expanded(
              child: filteredTeachers.isEmpty
                  ? Center(
                      child: Text('No teachers match “$_query”',
                          style: GoogleFonts.plusJakartaSans(fontSize: 13, color: ts)),
                    )
                  : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                itemCount: filteredTeachers.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: bd.withValues(alpha: .6)),
                itemBuilder: (_, i) {
                  final t = filteredTeachers[i];
                  final classes = _classesFor(t.id);
                  final selected = _selectedClasses[t.id] ?? const <String>{};
                  final isLeaving = selected.isNotEmpty;
                  final allSelected = classes.isNotEmpty && selected.length == classes.length;
                  final total = _totalCount(t.id);
                  final replacement = _replacements[t.id];

                  void toggleAll() => setState(() {
                    if (allSelected) {
                      _selectedClasses.remove(t.id);
                      _replacements.remove(t.id);
                    } else {
                      _selectedClasses[t.id] = classes.map((c) => c.id).toSet();
                    }
                  });

                  void toggleClass(String classId) => setState(() {
                    final set = _selectedClasses.putIfAbsent(t.id, () => <String>{});
                    if (set.contains(classId)) {
                      set.remove(classId);
                    } else {
                      set.add(classId);
                    }
                    if (set.isEmpty) {
                      _selectedClasses.remove(t.id);
                      _replacements.remove(t.id);
                    }
                  });

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      // Leave-all checkbox (tri-state: none / some / all of
                      // this teacher's classes selected for transfer)
                      SizedBox(
                        width: 36,
                        child: classes.isEmpty
                            ? null
                            : GestureDetector(
                                onTap: toggleAll,
                                child: Container(
                                  width: 22, height: 22,
                                  decoration: BoxDecoration(
                                    color: allSelected ? orange : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: isLeaving ? orange : bd, width: 1.4),
                                  ),
                                  child: allSelected
                                      ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                                      : (isLeaving
                                          ? Icon(Icons.remove_rounded, size: 16, color: orange)
                                          : null),
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      // Old teacher info
                      Expanded(flex: 3, child: Row(children: [
                        Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: isLeaving ? orange.withValues(alpha: .12) : (isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Center(child: Text(
                            t.name.isNotEmpty ? t.name[0].toUpperCase() : '?',
                            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 14,
                                color: isLeaving ? orange : ts),
                          )),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.name, style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700, fontSize: 13, color: isLeaving ? orange : tp),
                              overflow: TextOverflow.ellipsis),
                          if (t.department.isNotEmpty)
                            Text(t.department, style: GoogleFonts.plusJakartaSans(fontSize: 10, color: ts),
                                overflow: TextOverflow.ellipsis),
                          if (classes.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Wrap(spacing: 4, runSpacing: 4, children: [
                                for (final c in classes) Builder(builder: (_) {
                                  final isSel = selected.contains(c.id);
                                  return GestureDetector(
                                    onTap: () => toggleClass(c.id),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isSel
                                            ? orange.withValues(alpha: .15)
                                            : (isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                        borderRadius: BorderRadius.circular(6),
                                        border: isSel ? Border.all(color: orange, width: 1) : null,
                                      ),
                                      child: Text(_classLabel(c), style: GoogleFonts.plusJakartaSans(
                                          fontSize: 9, fontWeight: FontWeight.w600,
                                          color: isSel ? orange : ts)),
                                    ),
                                  );
                                }),
                              ]),
                            ),
                        ])),
                      ])),
                      // Slot count badge
                      SizedBox(
                        width: 70,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: total > 0
                                  ? (isLeaving ? orange.withValues(alpha: .15) : (isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)))
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              total > 0 ? '$total period${total != 1 ? "s" : ""}' : '—',
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10, fontWeight: FontWeight.w700,
                                  color: total > 0 ? (isLeaving ? orange : ts) : ts),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Replacement dropdown
                      Expanded(flex: 3, child: isLeaving
                          ? DropdownButtonFormField<String>(
                              initialValue: replacement?.id,
                              decoration: InputDecoration(
                                hintText: 'Select replacement…',
                                hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts),
                                filled: true,
                                fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bd)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                isDense: true,
                              ),
                              dropdownColor: cd,
                              style: GoogleFonts.plusJakartaSans(color: tp, fontSize: 12),
                              items: replacementCandidates
                                  .where((r) => r.id != t.id) // can't replace with self
                                  .map((r) => DropdownMenuItem<String>(
                                      value: r.id,
                                      child: Text(r.name, style: GoogleFonts.plusJakartaSans(fontSize: 12, color: tp))))
                                  .toList(),
                              onChanged: (v) => setState(() =>
                                  _replacements[t.id] = replacementCandidates.where((r) => r.id == v).firstOrNull),
                            )
                          : Text('—', style: GoogleFonts.plusJakartaSans(color: ts, fontSize: 13))),
                    ]),
                  );
                },
              ),
            ),
            ] else ...[
              Expanded(child: _buildSwapBody(isDark, tp, ts, cd, bd, orange)),
            ],

            // ── Footer ───────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
              decoration: BoxDecoration(
                color: cd,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                border: Border(top: BorderSide(color: bd)),
              ),
              child: !_swapMode
                  ? Row(children: [
                if (_activeTeacherIds.isNotEmpty) ...[
                  Icon(Icons.info_outline_rounded, size: 15, color: ts),
                  const SizedBox(width: 6),
                  Builder(builder: (_) {
                    final marked = _activeTeacherIds.length;
                    final assigned = _activeTeacherIds.where((id) => _replacements[id] != null).length;
                    return Text(
                      '$marked teacher${marked != 1 ? "s" : ""} marked • '
                      '$assigned replacement${assigned != 1 ? "s" : ""} assigned',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts),
                    );
                  }),
                ],
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel', style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700, color: ts, fontSize: 14)),
                ),
                const SizedBox(width: 12),
                AnimatedOpacity(
                  opacity: _canApply ? 1.0 : 0.45,
                  duration: const Duration(milliseconds: 200),
                  child: ElevatedButton.icon(
                    onPressed: (_canApply && !_applying) ? _apply : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: _applying
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text(_applying ? 'Applying…' : 'Apply All Transfers',
                        style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 14)),
                  ),
                ),
              ])
                  : Row(children: [
                Expanded(
                  child: Builder(builder: (_) {
                    final reason = _swapBlockedReason;
                    if (_swapSelected.length < 2) {
                      return Row(children: [
                        Icon(Icons.info_outline_rounded, size: 15, color: ts),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Pick two periods from the same class to swap.',
                            style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts))),
                      ]);
                    }
                    if (reason != null) {
                      return Row(children: [
                        const Icon(Icons.error_outline_rounded, size: 15, color: Colors.redAccent),
                        const SizedBox(width: 6),
                        Expanded(child: Text(reason,
                            style: GoogleFonts.plusJakartaSans(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.w600))),
                      ]);
                    }
                    final a = _swapAssignmentById(_swapSelected[0])!;
                    final b = _swapAssignmentById(_swapSelected[1])!;
                    return Row(children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 15, color: AppTheme.accentTeal),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Ready to swap ${a.teacher.name} ↔ ${b.teacher.name}.',
                          style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppTheme.accentTeal, fontWeight: FontWeight.w600))),
                    ]);
                  }),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel', style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700, color: ts, fontSize: 14)),
                ),
                const SizedBox(width: 12),
                AnimatedOpacity(
                  opacity: _canSwap ? 1.0 : 0.45,
                  duration: const Duration(milliseconds: 200),
                  child: ElevatedButton.icon(
                    onPressed: (_canSwap && !_swapping) ? _performSwap : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: _swapping
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text(_swapping ? 'Swapping…' : 'Swap Teachers',
                        style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 14)),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepChip(String num, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 18, height: 18,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Center(child: Text(num, style: GoogleFonts.plusJakartaSans(
            fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white))),
      ),
      const SizedBox(width: 6),
      Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    ]),
  );

  Widget _modeTab(String label, bool active, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? color : color.withValues(alpha: .3)),
        ),
        child: Text(label, style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w800, fontSize: 13,
            color: active ? Colors.white : color)),
      ),
    );
  }

  Widget _buildSwapBody(bool isDark, Color tp, Color ts, Color cd, Color bd, Color orange) {
    final classes = _vm.classes.toList()
      ..sort((a, b) => _classLabel(a).compareTo(_classLabel(b)));
    final periods = _swapClassId == null ? <Assignment>[] : _swapAssignmentsForClass(_swapClassId!);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _stepChip('1', 'Pick a class', orange),
          const SizedBox(width: 12),
          _stepChip('2', 'Pick two teachers', orange),
          const SizedBox(width: 12),
          _stepChip('3', 'Tap Swap', orange),
        ]),
        const SizedBox(height: 16),
        Text('Class', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: ts)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _swapClassId,
          decoration: InputDecoration(
            hintText: 'Select a class…',
            hintStyle: GoogleFonts.plusJakartaSans(fontSize: 13, color: ts),
            filled: true,
            fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bd)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          dropdownColor: cd,
          style: GoogleFonts.plusJakartaSans(color: tp, fontSize: 13),
          items: classes.map((c) => DropdownMenuItem<String>(
              value: c.id,
              child: Text(_classLabel(c), style: GoogleFonts.plusJakartaSans(fontSize: 13, color: tp)))).toList(),
          onChanged: (v) => setState(() {
            _swapClassId = v;
            _swapSelected.clear();
          }),
        ),
        const SizedBox(height: 18),
        if (_swapClassId != null) ...[
          Text('Tap two periods to swap their teachers',
              style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: ts)),
          const SizedBox(height: 8),
          if (periods.length < 2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('This class needs at least two scheduled periods to swap teachers.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts)),
            )
          else
            ...periods.map((a) {
              final pickIndex = _swapSelected.indexOf(a.id);
              final isPicked = pickIndex != -1;
              final pickColor = pickIndex == 0 ? orange : AppTheme.accentViolet;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: () => setState(() {
                    if (_swapSelected.contains(a.id)) {
                      _swapSelected.remove(a.id);
                    } else {
                      if (_swapSelected.length >= 2) _swapSelected.removeAt(0);
                      _swapSelected.add(a.id);
                    }
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isPicked ? pickColor.withValues(alpha: .12) : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC)),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isPicked ? pickColor : bd, width: isPicked ? 1.4 : 1),
                    ),
                    child: Row(children: [
                      if (isPicked)
                        Container(
                          width: 20, height: 20,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(color: pickColor, shape: BoxShape.circle),
                          child: Center(child: Text(pickIndex == 0 ? 'A' : 'B', style: GoogleFonts.plusJakartaSans(
                              fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white))),
                        )
                      else
                        const SizedBox(width: 30),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(a.teacher.name, style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, fontSize: 13, color: isPicked ? pickColor : tp)),
                        Text('${a.course.name} • ${a.slotLabel}',
                            style: GoogleFonts.plusJakartaSans(fontSize: 11, color: ts)),
                      ])),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${a.course.creditHours}h', style: GoogleFonts.plusJakartaSans(
                            fontSize: 11, fontWeight: FontWeight.w700, color: ts)),
                      ),
                    ]),
                  ),
                ),
              );
            }),
        ],
      ]),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// _SearchBar  — reusable animated search row for the matrix screen
// ─────────────────────────────────────────────────────────────────────────────
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final String query;
  final bool isDark;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final String hint;

  const _SearchBar({
    required this.controller,
    required this.query,
    required this.isDark,
    required this.onChanged,
    required this.onClear,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppTheme.bgCard : Colors.white;
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final tp = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final ts = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 44,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: query.isNotEmpty
              ? AppTheme.accentViolet.withValues(alpha: .5)
              : bd,
        ),
        boxShadow: query.isNotEmpty
            ? [
                BoxShadow(
                  color: AppTheme.accentViolet.withValues(alpha: .1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                )
              ]
            : null,
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(
            Icons.search_rounded,
            size: 18,
            color: query.isNotEmpty ? AppTheme.accentViolet : ts,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: GoogleFonts.plusJakartaSans(fontSize: 13, color: tp),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: GoogleFonts.plusJakartaSans(
                    fontSize: 13, color: ts),
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (query.isNotEmpty) ...[
            GestureDetector(
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppTheme.accentViolet.withValues(alpha: .15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      size: 12, color: AppTheme.accentViolet),
                ),
              ),
            ),
          ] else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}
