import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/allocator_viewmodel.dart';
import '../../viewmodels/backend_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../../models/teacher.dart';
import '../../models/course.dart';
import '../../models/class_model.dart';
import '../../models/room.dart';
import '../../models/time_slot.dart';
import '../../models/assignment.dart';
import '../../models/education_level.dart';
import '../../models/elective_group.dart';
import '../../app_theme.dart';
import '../../utils/responsive.dart';
import '../widgets/ga_report_panel.dart';
import '../widgets/selective_lock_dialog.dart';

// ── Theme helpers ─────────────────────────────────────────────────────────────
extension _AlTh on BuildContext {
  bool get _dk  => Theme.of(this).brightness == Brightness.dark;
  Color get _tp => _dk ? AppTheme.textPrimary   : AppTheme.lightText;
  Color get _ts => _dk ? AppTheme.textSecondary : AppTheme.lightTextSec;
  Color get _tm => _dk ? AppTheme.textMuted     : AppTheme.lightTextMut;
}

/// One relocation step in a make-space plan.
typedef _MsMove = ({Assignment card, TimeSlot from, TimeSlot to, List<int> days});

/// A verified make-space plan: relocations plus where the new course lands.
typedef _MsPlan = ({List<_MsMove> moves, TimeSlot place, List<int> days});

class AllocatorScreen extends StatefulWidget {
  final VoidCallback? onNavigateToSchedule;
  const AllocatorScreen({super.key, this.onNavigateToSchedule});
  @override
  State<AllocatorScreen> createState() => _AllocatorScreenState();
}

class _AllocatorScreenState extends State<AllocatorScreen> {
  bool _isFixingClashes = false;
  Teacher?    _teacher;
  Course?     _course;
  ClassModel? _class;

  bool         _autoDays    = true;
  Set<int>     _selectedDays = {};
  bool         _autoPeriod  = true;
  String?      _timeSlotId;
  // Room is no longer set from this form — it's assigned separately via the
  // Room Allocation box. _roomId is a read-only pass-through so editing an
  // existing assignment's days/time doesn't disturb its already-set room.
  String?      _roomId;
  bool         _showAdvanced = false; // collapsed by default

  // Set while an existing assignment is being edited — holds the original
  // so a failed/abandoned save can put it back instead of losing it.
  Assignment? _editBackup;

  // Assignment-list search — matches course, teacher, class/section, or room.
  final TextEditingController _assignSearchCtrl = TextEditingController();
  String _assignSearch = '';

  // Room Allocation box — separate search/filter state and which assignment
  // row currently has its room picker expanded.
  final TextEditingController _roomAllocSearchCtrl = TextEditingController();
  String  _roomAllocSearch      = '';
  bool    _roomAllocOnlyEmpty   = false;
  bool    _roomAllocOnlyClashes = false;
  String? _expandedRoomAssignmentId;
  // Room Allocation card collapsed by default so the Run GA button below is
  // reachable without scrolling through every assignment row.
  bool _roomAllocExpanded = false;

  static const _dayShort = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  @override
  void dispose() {
    _assignSearchCtrl.dispose();
    _roomAllocSearchCtrl.dispose();
    super.dispose();
  }

  bool get _step1Done => _teacher != null && _course != null && _class != null;

  bool get _daysReady {
    if (_autoDays) return _step1Done;
    return _selectedDays.isNotEmpty;
  }

  bool get _periodReady {
    if (_autoPeriod) return _step1Done;
    return _timeSlotId != null;
  }

  bool get _canAssign => _step1Done && _daysReady && _periodReady;

  void _resetSelections() {
    _selectedDays = {};
    _timeSlotId   = null;
  }

  bool _checkLock() {
    if (context.read<SettingsViewModel>().scheduleLocked) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.lock_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text('Schedule is locked. Unlock in settings to modify.',
                style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600))),
          ]),
          backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating));
      return true;
    }
    return false;
  }

  /// Pre-fill the form with an existing assignment for editing.
  /// Deletes the original first, then populates all form fields.
  /// The original is kept in `_editBackup` so `_restoreEditBackupIfAny` can
  /// put it back if the edit fails validation or is abandoned — see
  /// `_doAssign`, which is the only place that clears `_editBackup` for good.
  void _populateFormForEdit(Assignment a, DataEntryViewModel dataVm) {
    // If a different edit was already in progress, put that one back first
    // rather than silently stranding it.
    _restoreEditBackupIfAny(dataVm);

    _editBackup = a;
    dataVm.removeAssignment(a.id);
    // Remove explicit lock if it exists (so the manual UI override takes precedence)
    final existingLocks = dataVm.timeSlotLocks.where(
        (l) => l.courseId == a.course.id && (l.classId == null || l.classId == a.classModel.id)
    ).toList();
    for (final l in existingLocks) {
      dataVm.removeTimeSlotLock(l.id);
    }

    // IMPORTANT: look up by ID from the live VM lists so dropdown reference equality works.
    final teacher = dataVm.teachers.where((t) => t.id == a.teacher.id).firstOrNull;
    final course  = dataVm.courses.where((c) => c.id == a.course.id).firstOrNull;
    final cls     = dataVm.classes.where((c) => c.id == a.classModel.id).firstOrNull;
    setState(() {
      _teacher      = teacher;
      _course       = course;
      _class        = cls;
      _autoDays     = false;
      _selectedDays = a.occupiedSlots.toSet();
      _autoPeriod   = false;
      _timeSlotId   = a.timeSlotId;
      _roomId       = a.roomId; // preserved, not editable from this form
      _showAdvanced = true; // so the pre-filled Days/Period are visible
    });
  }

  /// Restore the assignment `_populateFormForEdit` removed, if the edit
  /// that followed never successfully completed. No-op if there's nothing
  /// to restore. Does not restore the explicit TimeSlotLock(s) that may have
  /// been removed alongside it — those have broader side effects on other
  /// assignments (see `addTimeSlotLock`) and re-applying them blindly on
  /// rollback would risk touching unrelated data.
  void _restoreEditBackupIfAny(DataEntryViewModel dataVm) {
    final backup = _editBackup;
    if (backup == null) return;
    _editBackup = null;
    dataVm.addAssignment(
      teacher: backup.teacher, course: backup.course, classModel: backup.classModel,
      startSlot: backup.startSlot, duration: backup.duration,
      timeSlotId: backup.timeSlotId, customDays: backup.customDays,
      roomId: backup.roomId, autoAssigned: backup.autoAssigned,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context._dk;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Consumer2<DataEntryViewModel, AllocatorViewModel>(
            builder: (ctx, dataVm, allocVm, _) {
              // Real-time clash detection when manual mode
              String? periodClash;
              if (!_autoPeriod && _timeSlotId != null && _teacher != null
                  && !_autoDays && _selectedDays.isNotEmpty && _class != null) {
                periodClash = allocVm.checkClash(
                  teacher: _teacher!,
                  startSlot: _selectedDays.reduce((a, b) => a < b ? a : b),
                  duration: _selectedDays.length,
                  timeSlotId: _timeSlotId!,
                  roomId: _roomId ?? '',
                  classModel: _class!,
                  existingAssignments: dataVm.assignments,
                  timeSlots: dataVm.timeSlots,
                  electiveGroups: dataVm.electiveGroups,
                );
              }

              final hp    = ctx.hPad;
              final backVm = ctx.watch<BackendViewModel>();

              return ListView(
                padding: EdgeInsets.fromLTRB(hp, 56, hp, 40),
                children: [
                  _header(isDark),
                  const SizedBox(height: 16),

                  // ── Elective Groups (Inter) — shown at top, always visible ──
                  _ElectiveGroupsSection(dataVm: dataVm),

                  // ── Normal assignment form ────────────────────────────────
                  const SizedBox(height: 20),
                  _addAssignmentCard(ctx, dataVm, allocVm, periodClash),

                  // ── Room Allocation — separate, manual-only ───────────────
                  const SizedBox(height: 20),
                  _roomAllocationCard(ctx, dataVm),

                  const SizedBox(height: 20),

                  // ── Credit-hour violations banner ─────────────────────────
                  if (allocVm.creditHourViolations.isNotEmpty) ...[
                    _creditHourBanner(ctx, allocVm.creditHourViolations, dataVm, allocVm),
                    const SizedBox(height: 16),
                  ],

                  // ── Teacher overload banner (real-minute feasibility) ─────
                  // 2 Bach slots == 3 Inter slots: teachers whose total weekly
                  // teaching minutes exceed the timetable's physical capacity
                  // can NEVER be scheduled clash-free — fix the data, not the GA.
                  Builder(builder: (_) {
                    final overloads = AllocatorViewModel.teacherOverloads(
                        dataVm.combinedAssignments, dataVm.timeSlots);
                    if (overloads.isEmpty) return const SizedBox.shrink();
                    return Column(children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.error.withValues(alpha: .35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.person_off_rounded, color: AppTheme.error, size: 16),
                              const SizedBox(width: 8),
                              Text('Over-booked Teachers (${overloads.length})',
                                  style: GoogleFonts.plusJakartaSans(
                                      fontWeight: FontWeight.w800, color: AppTheme.error, fontSize: 13)),
                            ]),
                            const SizedBox(height: 8),
                            ...overloads.map((v) => Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text('⚠ $v', style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11, color: ctx._ts)))),
                            const SizedBox(height: 6),
                            Text('No algorithm can schedule these clash-free — remove or reassign some of their courses first.',
                                style: GoogleFonts.plusJakartaSans(
                                    fontSize: 10, fontStyle: FontStyle.italic, color: AppTheme.error)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ]);
                  }),

                  // ── Error banner ──────────────────────────────────────────
                  if (allocVm.lastError != null) ...[
                    _errBanner(allocVm.lastError!),
                    const SizedBox(height: 16),
                  ],

                  // ── GA / Auto-generate panel ──────────────────────────────
                  if (dataVm.assignments.isNotEmpty || dataVm.electiveGroups.isNotEmpty) ...[
                    _GaPanel(dataVm: dataVm, vm: backVm,
                        onNavigateToSchedule: widget.onNavigateToSchedule),
                    const SizedBox(height: 20),
                  ],

                  // ── Assignment list ───────────────────────────────────────
                  if (dataVm.assignments.isNotEmpty) ...[
                    _listHeader(ctx, dataVm, allocVm),
                    const SizedBox(height: 12),
                    ..._filteredAssignments(dataVm)
                        .asMap().entries.map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _AssignmentTile(
                            index: e.key + 1, assignment: e.value,
                            timeSlots: dataVm.timeSlots, rooms: dataVm.rooms,
                            onDelete: () { if (!_checkLock()) dataVm.removeAssignment(e.value.id); },
                            onEdit: () { if (!_checkLock()) _populateFormForEdit(e.value, dataVm); }))),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ── New single-card form ───────────────────────────────────────────────────
  Widget _addAssignmentCard(BuildContext ctx, DataEntryViewModel dataVm,
      AllocatorViewModel allocVm, String? periodClash) {
    final isDark = ctx._dk;
    final cardBg = isDark ? AppTheme.bgCard : Colors.white;
    final bdCol  = isDark ? AppTheme.divider : AppTheme.lightDivider;

    if (dataVm.classes.isEmpty || dataVm.courses.isEmpty || dataVm.teachers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardBg, borderRadius: BorderRadius.circular(18),
          border: Border.all(color: bdCol),
        ),
        child: Column(children: [
          const Icon(Icons.info_outline_rounded, color: AppTheme.accentViolet, size: 36),
          const SizedBox(height: 12),
          Text('Set up your data first',
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800, fontSize: 16, color: ctx._tp)),
          const SizedBox(height: 6),
          Text('Go to Manage Data and add Teachers, Courses and Classes before creating assignments.',
              style: GoogleFonts.plusJakartaSans(fontSize: 13, color: ctx._ts, height: 1.55),
              textAlign: TextAlign.center),
        ]),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: cardBg, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: bdCol),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .2 : .04),
            blurRadius: 16, offset: const Offset(0,4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Card header ─────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          decoration: BoxDecoration(
            color: AppTheme.accentViolet.withValues(alpha: .08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            border: Border(bottom: BorderSide(color: bdCol)),
          ),
          child: Row(children: [
            Container(width: 32, height: 32,
                decoration: BoxDecoration(
                    gradient: AppTheme.violetGradient,
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.add_rounded, color: Colors.white, size: 18)),
            const SizedBox(width: 12),
            Text('Add Assignment',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, fontSize: 15, color: ctx._tp)),
          ]),
        ),

        // ── 3 dropdowns ─────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _step1(ctx, dataVm),

            const SizedBox(height: 18),

            // ── Advanced toggle ────────────────────────────────────────────
            GestureDetector(
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.bgMid : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: bdCol),
                ),
                child: Row(children: [
                  Icon(Icons.tune_rounded, size: 16,
                      color: _showAdvanced ? AppTheme.accentViolet : ctx._tm),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    _showAdvanced ? 'Hide advanced options'
                        : 'Advanced options — days & time',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: _showAdvanced ? AppTheme.accentViolet : ctx._ts),
                  )),
                  Icon(_showAdvanced
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                      size: 18, color: ctx._tm),
                ]),
              ),
            ),

            // ── Advanced section (expandable) ──────────────────────────────
            if (_showAdvanced) ...[
              const SizedBox(height: 16),
              _sectionLabel(ctx, 'Days', Icons.calendar_today_rounded, AppTheme.accentCyan),
              const SizedBox(height: 10),
              _step2Days(ctx, dataVm, allocVm),
              const SizedBox(height: 16),
              _sectionLabel(ctx, 'Time Period', Icons.schedule_rounded, AppTheme.accentViolet),
              const SizedBox(height: 10),
              _step2Period(ctx, dataVm, periodClash),
            ],

            const SizedBox(height: 18),

            // ── Editing banner + Cancel ──────────────────────────────────────
            if (_editBackup != null) ...[
              Row(children: [
                Icon(Icons.edit_outlined, size: 15, color: AppTheme.accentCyan),
                const SizedBox(width: 6),
                Expanded(child: Text('Editing an existing assignment',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12,
                        fontWeight: FontWeight.w600, color: AppTheme.accentCyan))),
                TextButton(
                  onPressed: () {
                    _restoreEditBackupIfAny(dataVm);
                    setState(() {
                      _teacher = null; _course = null; _class = null;
                      _selectedDays = {}; _timeSlotId = null;
                      _autoDays = true; _autoPeriod = true;
                      _roomId = null;
                      _showAdvanced = false;
                    });
                  },
                  child: Text('Cancel edit', style: GoogleFonts.plusJakartaSans(
                      fontSize: 12, fontWeight: FontWeight.w700, color: ctx._tm)),
                ),
              ]),
              const SizedBox(height: 10),
            ],

            // ── Add button ─────────────────────────────────────────────────
            _assignBtn(ctx, dataVm, allocVm, periodClash),
          ]),
        ),
      ]),
    );
  }

  Widget _sectionLabel(BuildContext ctx, String text, IconData icon, Color color) =>
      Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(text, style: GoogleFonts.plusJakartaSans(
            fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      ]);

  Widget _header(bool isDark) => Row(children: [
    Container(width: 48, height: 48,
        decoration: BoxDecoration(gradient: AppTheme.violetGradient,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: AppTheme.accentViolet.withValues(alpha: .4),
                blurRadius: 18, offset: const Offset(0,5))]),
        child: const Icon(Icons.account_tree_rounded, color: Colors.white, size: 24)),
    const SizedBox(width: 16),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Smart Allocator', style: GoogleFonts.plusJakartaSans(
          fontSize: 24, fontWeight: FontWeight.w800,
          color: isDark ? AppTheme.textPrimary : AppTheme.lightText, letterSpacing: -0.5)),
      Text('Assign clash-free slots to teacher-course pairs',
          style: GoogleFonts.plusJakartaSans(fontSize: 13,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
    ]),
  ]);

  Widget _step1(BuildContext ctx, DataEntryViewModel dataVm) {
    if (dataVm.classes.isEmpty || dataVm.courses.isEmpty || dataVm.teachers.isEmpty) {
      return _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentViolet,
          text: 'Add classes, courses and teachers in Manage Data first.');
    }
    return Column(children: [
      _Drop<ClassModel>(key: ValueKey('class-${_class?.id}'),
          label: 'Class / Section', icon: Icons.school_rounded,
          value: _class, color: AppTheme.accentViolet,
          items: { for (final c in dataVm.classes) c.id: c }.values.toList(),
          itemLabel: (c) => c.shortCode,
          onChanged: (v) => setState(() {
            _class = v;
            // Course list is level-scoped — drop a now-mismatched selection.
            if (_course != null && v != null && _course!.level != v.level) {
              _course = null;
            }
            _resetSelections();
          })),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (_, box) {
        final wide = box.maxWidth > 500;
        final coursesForClass = _class == null
            ? dataVm.courses
            : dataVm.courses.where((c) => c.level == _class!.level).toList();
        final cDrop = _Drop<Course>(key: ValueKey('course-${_course?.id}'),
            label: 'Course', icon: Icons.menu_book_outlined,
            value: _course, color: AppTheme.accentViolet,
            items: { for (final c in coursesForClass) c.id: c }.values.toList(),
            itemLabel: (c) => '${c.name}  (${c.code})',
            onChanged: (v) => setState(() => _course = v));
        final tDrop = _Drop<Teacher>(key: ValueKey('teacher-${_teacher?.id}'),
            label: 'Teacher', icon: Icons.person_outline_rounded,
            value: _teacher, color: AppTheme.accentViolet,
            items: { for (final t in dataVm.teachers) t.id: t }.values.toList(),
            itemLabel: (t) => t.name,
            onChanged: (v) => setState(() { _teacher = v; _resetSelections(); }));
        return wide
            ? Row(children: [Expanded(child: cDrop), const SizedBox(width: 12), Expanded(child: tDrop)])
            : Column(children: [cDrop, const SizedBox(height: 12), tDrop]);
      }),
    ]);
  }

  Widget _step2Days(BuildContext ctx, DataEntryViewModel dataVm, AllocatorViewModel allocVm) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _MiniToggle(
        leftLabel: 'Auto', rightLabel: 'Manual',
        leftSub: 'AI picks best days', rightSub: 'Tap days yourself',
        isLeft: _autoDays,
        leftColor: AppTheme.accentCyan, rightColor: AppTheme.accentViolet,
        onLeft:  () => setState(() { _autoDays = true;  _selectedDays = {}; }),
        onRight: () => setState(() => _autoDays = false),
      ),
      const SizedBox(height: 16),
      if (_autoDays) ...[
        if (!_step1Done)
          _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentCyan,
              text: 'Complete Step 1 to preview the AI-selected days.')
        else
          _autoDaysPreview(ctx, dataVm, allocVm),
      ] else ...[
        Text('Tap any days you want - select as many as needed',
            style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._tm)),
        const SizedBox(height: 12),
        _DayGrid(
          workingDays: context.read<SettingsViewModel>().workingDays,
          occupiedDays: _busyDays(dataVm),
          selectedDays: _selectedDays,
          color: AppTheme.accentViolet,
          readOnly: false,
          onToggle: (day) => setState(() {
          if (_selectedDays.contains(day)) { _selectedDays.remove(day); }
            else { _selectedDays.add(day); }
          }),
        ),
        const SizedBox(height: 12),
        if (_selectedDays.isEmpty)
          Text('No days selected - tap the grid above',
              style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._tm))
        else
          _DaysSummary(selectedDays: _selectedDays, workingDays: context.read<SettingsViewModel>().workingDays),
      ],
    ]);
  }

  bool _slotsOverlap(DataEntryViewModel dataVm, String tsIdA, String tsIdB) {
    if (tsIdA == tsIdB) return true;
    final slotA = dataVm.timeSlots.where((t) => t.id == tsIdA).firstOrNull;
    final slotB = dataVm.timeSlots.where((t) => t.id == tsIdB).firstOrNull;
    if (slotA == null || slotB == null) return false;
    int parseMin(String t) {
      final p = t.split(':');
      if (p.length != 2) return 0;
      return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
    }
    final aS = parseMin(slotA.startTime), aE = parseMin(slotA.endTime);
    final bS = parseMin(slotB.startTime), bE = parseMin(slotB.endTime);
    return aS < bE && bS < aE;
  }

  Set<int> _busyDays(DataEntryViewModel dataVm) {

    final result = <int>{};
    final workingDaysCount = context.read<SettingsViewModel>().workingDays;
    
    if (!_autoPeriod && _timeSlotId != null) {
      for (int day = 1; day <= workingDaysCount; day++) {
        bool teacherBusy = false;
        if (_teacher != null) {
          teacherBusy = dataVm.assignments.any((a) =>
              a.teacher.id == _teacher!.id &&
              a.occupiedSlots.contains(day) &&
              _slotsOverlap(dataVm, a.timeSlotId, _timeSlotId!));
          if (!teacherBusy) {
            teacherBusy = dataVm.electiveGroups.any((eg) =>
                eg.timeSlotId.isNotEmpty &&
                dataVm.electiveOccupiedDays(eg).contains(day) &&
                eg.entries.any((e) => e.teacherId == _teacher!.id) &&
                _slotsOverlap(dataVm, eg.timeSlotId, _timeSlotId!));
          }
        }
        bool classBusy = _class != null && dataVm.occupiedTimeSlotIdsForClass(_class!.id, day).contains(_timeSlotId!);
        
        if (teacherBusy || classBusy) {
          result.add(day);
        }
      }
    } else {
      final validSlots = _class == null ? dataVm.timeSlots : dataVm.timeSlots.where((t) => t.level == _class!.level).toList();
      if (validSlots.isEmpty) return result;
      
      for (int day = 1; day <= workingDaysCount; day++) {
        bool allTaken = true;
        for (final ts in validSlots) {
          bool teacherBusy = false;
          if (_teacher != null) {
            teacherBusy = dataVm.assignments.any((a) =>
                a.teacher.id == _teacher!.id &&
                a.occupiedSlots.contains(day) &&
                _slotsOverlap(dataVm, a.timeSlotId, ts.id));
            if (!teacherBusy) {
              teacherBusy = dataVm.electiveGroups.any((eg) =>
                  eg.timeSlotId.isNotEmpty &&
                  dataVm.electiveOccupiedDays(eg).contains(day) &&
                  eg.entries.any((e) => e.teacherId == _teacher!.id) &&
                  _slotsOverlap(dataVm, eg.timeSlotId, ts.id));
            }
          }
          bool classBusy = _class != null && dataVm.occupiedTimeSlotIdsForClass(_class!.id, day).contains(ts.id);
          
          if (!teacherBusy && !classBusy) {
            allTaken = false;
            break;
          }
        }
        if (allTaken) {
          result.add(day);
        }
      }
    }
    return result;
  }

  Widget _step2Period(BuildContext ctx, DataEntryViewModel dataVm, String? clash) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _MiniToggle(
        leftLabel: 'Auto', rightLabel: 'Manual',
        leftSub: 'AI picks best period', rightSub: 'Choose period yourself',
        isLeft: _autoPeriod,
        leftColor: AppTheme.accentCyan, rightColor: AppTheme.accentViolet,
        onLeft:  () => setState(() { _autoPeriod = true; _timeSlotId = null; }),
        onRight: () => setState(() => _autoPeriod = false),
      ),
      const SizedBox(height: 16),
      if (_autoPeriod) ...[
        if (!_step1Done)
          _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentCyan,
              text: 'Complete Step 1 to preview the AI-selected period.')
        else
          _autoPeriodPreview(dataVm),
      ] else ...[
        if (dataVm.timeSlots.isEmpty)
          _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentViolet,
              text: 'No time slots yet. Add them in Manage Data and Time Slots.')
        else ...[
          Text('Select a time period', style: GoogleFonts.plusJakartaSans(
              fontSize: 12, color: ctx._tm)),
          const SizedBox(height: 12),
          _PeriodGrid(
            timeSlots: _class == null
                ? dataVm.timeSlots
                : dataVm.timeSlots.where((t) => t.level == _class!.level).toList(),
            selectedId: _timeSlotId,
            busyIds: _teacher == null ? {} : _busyPeriodIds(dataVm),
            onSelect: (id) => setState(() => _timeSlotId = id),
          ),
          if (clash != null) ...[
            const SizedBox(height: 12),
            _InfoBox(icon: Icons.error_outline_rounded, color: AppTheme.error, text: clash),
          ],
        ],
      ],
    ]);
  }

  Set<String> _busyPeriodIds(DataEntryViewModel dataVm) {
    if (_teacher == null) return {};
    // Only run the expensive auto-finder when its result is actually used —
    // in Manual-Days mode it was previously computed here unconditionally
    // and immediately discarded, which was a real cost on every rebuild.
    final days = _autoDays
        ? (_autoFindResult(dataVm) ?? <int>{}).toSet()
        : _selectedDays;
    if (days.isEmpty) return {};
    final result = <String>{};
    for (final day in days) {
      result.addAll(dataVm.occupiedTimeSlotIdsForTeacher(_teacher!.id, day));
    }
    // Only return IDs that belong to the selected class's level
    final levelSlotIds = dataVm.timeSlots
        .where((t) => _class == null || t.level == _class!.level)
        .map((t) => t.id)
        .toSet();
    return result.intersection(levelSlotIds);
  }

  List<int>? _autoFindResult(DataEntryViewModel dataVm) {
    if (_teacher == null) return null;
    final creditHours = _course?.creditHours ?? 3;
    final workingDaysCount = context.read<SettingsViewModel>().workingDays;
    final allDays = List.generate(workingDaysCount, (i) => i + 1);

    final candidates = <int>{
      creditHours,
      if (creditHours > 1) creditHours - 1,
      creditHours + 1,
    }.where((d) => d >= 1 && d <= workingDaysCount).toList()
      ..sort((a, b) => (a - creditHours).abs().compareTo((b - creditHours).abs()));

    final validSlots = dataVm.timeSlots
        .where((t) => _class == null || t.level == _class!.level)
        .toList();

    if (validSlots.isEmpty) return null;



    bool isDaySlotFree(String tsId, int day) {
      // Teacher busy? Check exact slot ID AND any cross-level time-overlapping slot
      final teacherBusy = dataVm.assignments.any((a) =>
      a.teacher.id == _teacher!.id &&
          a.occupiedSlots.contains(day) &&
          _slotsOverlap(dataVm, a.timeSlotId, tsId));
      final teacherElectiveBusy = dataVm.electiveGroups.any((eg) =>
          eg.timeSlotId.isNotEmpty &&
          dataVm.electiveOccupiedDays(eg).contains(day) &&
          eg.entries.any((e) => e.teacherId == _teacher!.id) &&
          _slotsOverlap(dataVm, eg.timeSlotId, tsId));
      // Class attending an elective group in an overlapping slot? Only the
      // elective's own days are reserved — leftover days may be proposed.
      final classElectiveBusy = _class != null &&
          dataVm.electiveGroups.any((eg) =>
              eg.timeSlotId.isNotEmpty &&
              dataVm.electiveOccupiedDays(eg).contains(day) &&
              eg.classIds.contains(_class!.id) &&
              _slotsOverlap(dataVm, eg.timeSlotId, tsId));
      // Class busy? Only exact same slot matters (same level)
      final classBusy = _class == null
          ? false
          : dataVm.occupiedTimeSlotIdsForClass(_class!.id, day).contains(tsId);
      return !teacherBusy && !teacherElectiveBusy && !classElectiveBusy && !classBusy;
    }

    // Build a map: slotId -> list of free days for this teacher+class combo
    final Map<String, List<int>> freeDaysPerSlot = {};
    for (final ts in validSlots) {
      freeDaysPerSlot[ts.id] = allDays
          .where((day) => isDaySlotFree(ts.id, day))
          .toList();
    }

    for (final dur in candidates) {
      // Pass 1: Try consecutive blocks in each valid slot. Within a slot,
      // prefer blocks anchored to a week edge (start Mon, else end on the
      // last working day) — the college pattern tiles a period as
      // (1-k)+(k+1-end), so a mid-week block like 2-4 is a last resort.
      for (final ts in validSlots) {
        final freeDays = freeDaysPerSlot[ts.id]!;
        List<int>? bestWin;
        int bestRank = 3;
        // Sliding window over free days looking for `dur` consecutive days
        for (int i = 0; i <= freeDays.length - dur; i++) {
          final window = freeDays.sublist(i, i + dur);
          // Check if this window is actually consecutive calendar days
          bool isConsec = true;
          for (int j = 1; j < window.length; j++) {
            if (window[j] != window[j - 1] + 1) { isConsec = false; break; }
          }
          if (!isConsec) continue;
          final r = window.first == 1 ? 0 : (window.last == workingDaysCount ? 1 : 2);
          if (r < bestRank) { bestRank = r; bestWin = window; }
          if (bestRank == 0) break;
        }
        if (bestWin != null) return bestWin;
      }

      // Pass 2: Non-consecutive — any `dur` free days in the same slot
      for (final ts in validSlots) {
        final freeDays = freeDaysPerSlot[ts.id]!;
        if (freeDays.length >= dur) {
          return freeDays.sublist(0, dur);
        }
      }
    }

    // Pass 3: Best-effort — return the slot with the most free days
    // (let user see partial; upstream caller shows better error)
    String? bestSlotId;
    int bestCount = 0;
    for (final ts in validSlots) {
      final count = freeDaysPerSlot[ts.id]!.length;
      if (count > bestCount) { bestCount = count; bestSlotId = ts.id; }
    }
    if (bestSlotId != null && bestCount > 0) {
      final days = freeDaysPerSlot[bestSlotId]!;
      // Return whatever free days exist (caller decides if enough)
      return days.isEmpty ? null : days;
    }
    return null;
  }

  int? allocVmPreviewStart(DataEntryViewModel dataVm) =>
      _autoFindResult(dataVm)?.firstOrNull;

  Widget _autoDaysPreview(BuildContext ctx, DataEntryViewModel dataVm, AllocatorViewModel allocVm) {
    final result = _autoFindResult(dataVm);
    if (result == null) {
      return _InfoBox(icon: Icons.warning_amber_rounded, color: AppTheme.accentAmber,
          text: 'No free days found for ${_teacher!.name}. Remove an assignment first.');
    }
    final start = result.first;
    final dur   = result.length;
    final previewDays = result.toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _Chip('${dur}d block', AppTheme.accentCyan, Icons.view_column_rounded),
        const SizedBox(width: 8),
        _Chip('${_dayShort[start-1]}-${_dayShort[start+dur-2]}',
            AppTheme.accentCyan, Icons.calendar_today_rounded),
      ]),
      const SizedBox(height: 12),
      _DayGrid(
          workingDays: context.read<SettingsViewModel>().workingDays,
          occupiedDays: _busyDays(dataVm),
          selectedDays: previewDays,
          color: AppTheme.accentCyan,
          readOnly: true,
          onToggle: null),
      const SizedBox(height: 10),
      _InfoBox(icon: Icons.auto_awesome_rounded, color: AppTheme.accentCyan,
          text: 'Consecutive days preferred (e.g. Mon-Wed, Thu-Sat).'),
    ]);
  }

  /// The period Auto mode would currently preview-select, given the
  /// preview day (from Auto/Manual Days). Shared by the Period preview and
  /// the Room-availability preview, so both agree on "the slot in play".
  TimeSlot? _autoPeriodSlot(DataEntryViewModel dataVm) {
    final refDay = _autoDays
        ? (allocVmPreviewStart(dataVm) ?? 1)
        : (_selectedDays.isEmpty ? 1 : _selectedDays.first);
    // Only show slots matching the selected class level
    final levelSlots = _class == null
        ? dataVm.timeSlots
        : dataVm.timeSlots.where((t) => t.level == _class!.level).toList();
    if (levelSlots.isEmpty) return null;
    return levelSlots.firstWhere(
        (ts) => !dataVm.occupiedTimeSlotIdsForTeacher(_teacher!.id, refDay).contains(ts.id),
        orElse: () => levelSlots.first);
  }

  Widget _autoPeriodPreview(DataEntryViewModel dataVm) {
    final freePeriod = _autoPeriodSlot(dataVm);
    if (freePeriod == null) {
      return _InfoBox(icon: Icons.warning_amber_rounded, color: AppTheme.accentAmber,
          text: 'No time slots configured. Add slots in Manage Data and Time Slots.');
    }
    return Row(children: [
      _Chip('Auto-selected', AppTheme.accentCyan, Icons.auto_awesome_rounded),
      const SizedBox(width: 8),
      _Chip(freePeriod.label, AppTheme.accentViolet, Icons.schedule_rounded),
    ]);
  }

  /// Rooms occupied by any existing assignment — any education level — whose
  /// days intersect [days] and whose time slot clock-overlaps [timeSlotId].
  /// Level-agnostic on purpose: a physical room is shared between
  /// Intermediate and Bachelors schedules. Used by the Room Allocation box;
  /// [excludeAssignmentId] lets an assignment being re-assigned ignore its
  /// own current room.
  Set<String> _busyRoomIds(DataEntryViewModel dataVm,
      {required List<int> days, required String? timeSlotId, String? excludeAssignmentId}) {
    if (timeSlotId == null || days.isEmpty) return {};
    final tsObj = dataVm.timeSlots.where((t) => t.id == timeSlotId).firstOrNull;
    int pm(String t) {
      final p = t.split(':');
      return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
    }
    bool overlaps(TimeSlot a, TimeSlot b) =>
        pm(a.startTime) < pm(b.endTime) && pm(b.startTime) < pm(a.endTime);
    final daySet = days.toSet();
    final busy = <String>{};
    for (final a in dataVm.assignments) {
      if (a.id == excludeAssignmentId) continue;
      final roomId = a.roomId;
      if (roomId == null) continue;
      final aSlot = dataVm.timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      final timesOverlap = a.timeSlotId == timeSlotId ||
          (tsObj != null && aSlot != null && overlaps(tsObj, aSlot));
      if (!timesOverlap) continue;
      if (a.occupiedSlots.toSet().intersection(daySet).isEmpty) continue;
      busy.add(roomId);
    }
    return busy;
  }

  // ── Room Allocation box — separate, manual-only room assignment ────────────
  // Rooms are never touched by the GA (see ga_engine.dart/backend_viewmodel.dart);
  // this is the only place a room gets set, changed, or cleared.

  /// Whether [a]'s currently-assigned room is actually double-booked against
  /// another assignment (any level — a physical room is shared between
  /// Intermediate and Bachelors). Room-less assignments never "clash".
  /// Catches rooms left over from before the GA stopped touching rooms —
  /// the picker itself can't create a new clash since it disables tapping
  /// an occupied room, but pre-existing ones need to be surfaced somewhere.
  bool _roomHasClash(DataEntryViewModel dataVm, Assignment a) {
    if (!a.hasRoom) return false;
    // A room that no longer exists in the data can't clash — it's a stale
    // reference left by a deleted room, surfaced separately for cleanup.
    if (dataVm.rooms.where((r) => r.id == a.roomId).firstOrNull == null) {
      return false;
    }
    return _busyRoomIds(dataVm,
            days: a.occupiedSlots, timeSlotId: a.timeSlotId, excludeAssignmentId: a.id)
        .contains(a.roomId);
  }

  Widget _roomAllocationCard(BuildContext ctx, DataEntryViewModel dataVm) {
    final isDark = ctx._dk;
    final cardBg = isDark ? AppTheme.bgCard : Colors.white;
    final bdCol  = isDark ? AppTheme.divider : AppTheme.lightDivider;

    if (dataVm.assignments.isEmpty) return const SizedBox.shrink();

    final clashingIds = dataVm.assignments
        .where((a) => _roomHasClash(dataVm, a)).map((a) => a.id).toSet();

    final query = _roomAllocSearch.trim().toLowerCase();
    final list = dataVm.assignments.where((a) {
      if (_roomAllocOnlyEmpty && a.hasRoom) return false;
      if (_roomAllocOnlyClashes && !clashingIds.contains(a.id)) return false;
      if (query.isEmpty) return true;
      final roomName = a.hasRoom
          ? (dataVm.rooms.where((r) => r.id == a.roomId).firstOrNull?.name ?? '')
          : '';
      return a.course.name.toLowerCase().contains(query) ||
          a.course.code.toLowerCase().contains(query) ||
          a.teacher.name.toLowerCase().contains(query) ||
          a.classModel.shortCode.toLowerCase().contains(query) ||
          roomName.toLowerCase().contains(query);
    }).toList();

    final validRoomIds = dataVm.rooms.map((r) => r.id).toSet();
    final staleRoomCount = dataVm.assignments
        .where((a) => a.hasRoom && !validRoomIds.contains(a.roomId))
        .length;
    final assignedCount = dataVm.assignments
        .where((a) => a.hasRoom && validRoomIds.contains(a.roomId))
        .length;

    return Container(
      decoration: BoxDecoration(
        color: cardBg, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: bdCol),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .2 : .04),
            blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Card header (tap to expand/collapse, like Elective Groups) ──────
        InkWell(
          onTap: () => setState(() => _roomAllocExpanded = !_roomAllocExpanded),
          borderRadius: _roomAllocExpanded
              ? const BorderRadius.vertical(top: Radius.circular(18))
              : BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: AppTheme.accentAmber.withValues(alpha: .08),
              borderRadius: _roomAllocExpanded
                  ? const BorderRadius.vertical(top: Radius.circular(18))
                  : BorderRadius.circular(18),
              border: _roomAllocExpanded
                  ? Border(bottom: BorderSide(color: bdCol))
                  : null,
            ),
            child: Row(children: [
              Container(width: 32, height: 32,
                  decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [AppTheme.accentAmber, Color(0xFFF97316)]),
                      borderRadius: BorderRadius.circular(9)),
                  child: const Icon(Icons.meeting_room_rounded, color: Colors.white, size: 18)),
              const SizedBox(width: 12),
              Expanded(child: Text('Room Allocation',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, fontSize: 15, color: ctx._tp))),
              Text('$assignedCount/${dataVm.assignments.length} assigned',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 11, fontWeight: FontWeight.w700, color: ctx._ts)),
              const SizedBox(width: 8),
              Icon(_roomAllocExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: AppTheme.accentAmber, size: 22),
            ]),
          ),
        ),

        if (_roomAllocExpanded) Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                'Rooms are assigned manually here — Add Assignment and the '
                'auto-generator never pick or change a room. Checked across '
                'both Intermediate and Bachelors — a physical room is shared '
                'between levels.',
                style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._ts, height: 1.5)),
            const SizedBox(height: 14),

            if (staleRoomCount > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.accentAmber.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppTheme.accentAmber.withValues(alpha: .35)),
                ),
                child: Row(children: [
                  const Icon(Icons.link_off_rounded,
                      color: AppTheme.accentAmber, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(
                          '$staleRoomCount assignment${staleRoomCount > 1 ? 's' : ''} '
                          'still point${staleRoomCount > 1 ? '' : 's'} to deleted room(s).',
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.accentAmber))),
                  TextButton(
                      onPressed: () {
                        final n = dataVm.clearUnknownRoomAllocations();
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content: Text(
                                'Cleared $n stale room link${n == 1 ? '' : 's'}.')));
                      },
                      child: const Text('Clear links')),
                ]),
              ),
              const SizedBox(height: 14),
            ],

            if (clashingIds.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.error.withValues(alpha: .35)),
                ),
                child: Row(children: [
                  Icon(Icons.warning_rounded, color: AppTheme.error, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                      '${clashingIds.length} room clash${clashingIds.length > 1 ? 'es' : ''} — '
                      'the same room is double-booked at an overlapping time. '
                      'Pick a different room for the highlighted row(s) below.',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.error))),
                ]),
              ),
              const SizedBox(height: 14),
            ],

            Row(children: [
              Expanded(child: TextField(
                controller: _roomAllocSearchCtrl,
                onChanged: (v) => setState(() => _roomAllocSearch = v),
                style: GoogleFonts.plusJakartaSans(fontSize: 13, color: ctx._tp),
                decoration: InputDecoration(
                  hintText: 'Search course, teacher, class or room…',
                  hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._tm),
                  prefixIcon: Icon(Icons.search_rounded, size: 18, color: ctx._tm),
                  isDense: true,
                  filled: true, fillColor: isDark ? AppTheme.bgMid : const Color(0xFFF8FAFC),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdCol)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdCol)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.accentAmber, width: 1.5)),
                ),
              )),
              const SizedBox(width: 10),
              FilterChip(
                label: Text('Room-less only', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w600)),
                selected: _roomAllocOnlyEmpty,
                onSelected: (v) => setState(() => _roomAllocOnlyEmpty = v),
                selectedColor: AppTheme.accentAmber.withValues(alpha: .18),
                checkmarkColor: AppTheme.accentAmber,
              ),
              if (clashingIds.isNotEmpty) ...[
                const SizedBox(width: 8),
                FilterChip(
                  label: Text('Clashing only (${clashingIds.length})', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w600)),
                  selected: _roomAllocOnlyClashes,
                  onSelected: (v) => setState(() => _roomAllocOnlyClashes = v),
                  selectedColor: AppTheme.error.withValues(alpha: .15),
                  checkmarkColor: AppTheme.error,
                ),
              ],
            ]),
            const SizedBox(height: 14),

            if (dataVm.rooms.isEmpty)
              _InfoBox(icon: Icons.warning_amber_rounded, color: AppTheme.accentAmber,
                  text: 'No rooms added. Go to Manage Data and Rooms first.')
            else if (list.isEmpty)
              _InfoBox(icon: Icons.info_outline_rounded, color: AppTheme.accentCyan,
                  text: 'No assignments match.')
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 560),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) => _roomAllocRow(ctx, dataVm, list[i]),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  // Sets/clears an assignment's room, confirms it with a snackbar, and
  // collapses the row so working through many assignments is a fast
  // tap-pick-confirm-next loop instead of leaving every row expanded.
  void _setRoomAndConfirm(BuildContext ctx, DataEntryViewModel dataVm,
      Assignment a, String? roomId) {
    dataVm.setAssignmentRoom(a.id, roomId);
    setState(() => _expandedRoomAssignmentId = null);
    final roomName = roomId == null
        ? null
        : dataVm.rooms.where((r) => r.id == roomId).firstOrNull?.name;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(
            roomId == null
                ? 'Room cleared for ${a.course.code} · ${a.classModel.shortCode}'
                : 'Room $roomName assigned to ${a.course.code} · ${a.classModel.shortCode}',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        backgroundColor: roomId == null ? AppTheme.error : const Color(0xFF0D9488),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
  }

  Widget _roomAllocRow(BuildContext ctx, DataEntryViewModel dataVm, Assignment a) {
    final isDark = ctx._dk;
    final expanded = _expandedRoomAssignmentId == a.id;
    final room = a.hasRoom ? dataVm.rooms.where((r) => r.id == a.roomId).firstOrNull : null;
    final ts = dataVm.timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
    final clash = _roomHasClash(dataVm, a);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: clash
            ? AppTheme.error.withValues(alpha: .06)
            : (isDark ? AppTheme.bgMid : const Color(0xFFF8FAFC)),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: clash
            ? AppTheme.error.withValues(alpha: .4)
            : (isDark ? AppTheme.divider : AppTheme.lightDivider)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: () => setState(() =>
              _expandedRoomAssignmentId = expanded ? null : a.id),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 34,
            child: Row(children: [
              Expanded(child: Text(
                  '${a.course.code} · ${a.classModel.shortCode} · ${a.teacher.name} · '
                  '${a.daysLabel} · ${ts?.shortLabel ?? a.timeSlotId}',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w600, fontSize: 12, color: ctx._tp),
                  overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              _Chip(clash ? '${room?.name} occupied' : (room?.name ?? 'No room'),
                  clash ? AppTheme.error
                      : room != null ? AppTheme.accentTeal : AppTheme.accentAmber,
                  clash ? Icons.error_rounded
                      : room != null ? Icons.meeting_room_rounded : Icons.warning_amber_rounded),
              const SizedBox(width: 6),
              Icon(expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                  size: 16, color: ctx._tm),
            ]),
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Tap a room to assign it — saves immediately:',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 11, fontWeight: FontWeight.w600, color: ctx._ts))),
            if (room != null)
              GestureDetector(
                onTap: () => _setRoomAndConfirm(ctx, dataVm, a, null),
                child: Text('Clear room', style: GoogleFonts.plusJakartaSans(
                    fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.error)),
              ),
          ]),
          const SizedBox(height: 8),
          _RoomGrid(
            rooms: dataVm.rooms,
            selectedId: a.roomId,
            busyIds: _busyRoomIds(dataVm,
                days: a.occupiedSlots, timeSlotId: a.timeSlotId, excludeAssignmentId: a.id),
            onSelect: (id) => _setRoomAndConfirm(ctx, dataVm, a, id),
          ),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }

  Widget _assignBtn(BuildContext ctx, DataEntryViewModel dataVm,
      AllocatorViewModel allocVm, String? clash) {
    final ready = _canAssign && clash == null;
    final isLocked = ctx.watch<SettingsViewModel>().scheduleLocked;

    if (!ready || isLocked) {
      return Container(
          height: 50,
          decoration: BoxDecoration(
              color: ctx._dk ? AppTheme.bgMid : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: isLocked ? AppTheme.error.withValues(alpha: 0.5) : (ctx._dk ? AppTheme.divider : AppTheme.lightDivider))),
          child: Center(child: Text(
              isLocked
                  ? '🔒 Schedule Locked'
                  : !_step1Done
                      ? 'Select class, course and teacher above'
                      : !_daysReady ? 'Pick days in Advanced options'
                      : !_periodReady ? 'Pick a time in Advanced options'
                      : clash != null ? 'Time clash detected — change period'
                      : 'Ready to add',
              style: GoogleFonts.plusJakartaSans(color: isLocked ? AppTheme.error : ctx._tm, fontSize: 12, fontWeight: isLocked ? FontWeight.w700 : FontWeight.normal),
              textAlign: TextAlign.center)));
    }
    final bothAuto = _autoDays && _autoPeriod;
    return GestureDetector(
        onTap: () => _doAssign(dataVm, allocVm),
        child: Container(
            height: 50,
            decoration: BoxDecoration(
                gradient: bothAuto ? AppTheme.cyanGradient : AppTheme.violetGradient,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(
                    color: (bothAuto
                        ? AppTheme.accentCyan : AppTheme.accentViolet).withValues(alpha: .4),
                    blurRadius: 14, offset: const Offset(0,4))]),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(bothAuto ? Icons.auto_awesome_rounded : Icons.add_link_rounded,
                  color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Text(bothAuto ? '＋ Add (Auto-Assign)' : '＋ Add Assignment',
                  style: GoogleFonts.plusJakartaSans(fontSize: 14,
                      fontWeight: FontWeight.w800, color: Colors.white)),
            ])));
  }

  Widget _creditHourBanner(BuildContext ctx, List<String> violations, DataEntryViewModel dataVm, AllocatorViewModel allocVm) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.accentAmber.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.accentAmber.withValues(alpha: .35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.school_rounded, color: AppTheme.accentAmber, size: 16),
              const SizedBox(width: 8),
              Text('Credit Hour Mismatches (${violations.length})',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: AppTheme.accentAmber, fontSize: 13)),
            ]),
            const SizedBox(height: 8),
            ...violations.map((v) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber_rounded,
                    color: AppTheme.accentAmber.withValues(alpha: .7), size: 13),
                const SizedBox(width: 6),
                Expanded(child: Text(v, style: GoogleFonts.plusJakartaSans(
                    fontSize: 12, color: ctx._ts, height: 1.4))),
              ]),
            )),
            const SizedBox(height: 6),
            Text('Add or remove assignments to match each course\'s credit hours.',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 11, color: AppTheme.accentAmber.withValues(alpha: .8),
                    fontStyle: FontStyle.italic)),
            const SizedBox(height: 10),
            // One-tap cleanup: deletes surplus duplicate assignments
            // (same course + class over credit budget). Keeps pinned copies.
            GestureDetector(
              onTap: () {
                final removed = dataVm.removeDuplicateAssignments();
                // Re-validate so counts/banners refresh immediately
                allocVm.validateAndApply(dataVm.assignments, dataVm.timeSlots,
                    combinedRules: dataVm.combinedRules, rooms: dataVm.rooms);
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                  duration: const Duration(seconds: 5),
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: removed.isEmpty ? AppTheme.accentTeal : AppTheme.accentAmber,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  content: Text(
                    removed.isEmpty
                        ? 'No removable duplicates — remaining mismatches are day-count issues on single assignments.'
                        : '${removed.length} duplicate(s) removed:\n${removed.take(6).map((x) => '• $x').join('\n')}${removed.length > 6 ? '\n…and ${removed.length - 6} more' : ''}',
                    style: GoogleFonts.plusJakartaSans(color: Colors.white, fontSize: 12),
                  ),
                ));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: AppTheme.accentAmber,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [BoxShadow(
                      color: AppTheme.accentAmber.withValues(alpha: .35),
                      blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cleaning_services_rounded, color: Colors.white, size: 15),
                  const SizedBox(width: 6),
                  Text('Auto-remove extra duplicates',
                      style: GoogleFonts.plusJakartaSans(
                          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                ]),
              ),
            ),
          ],
        ),
      );

  Widget _errBanner(String e) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.error.withValues(alpha: .3))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline_rounded, color: AppTheme.error, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(e, style: GoogleFonts.plusJakartaSans(
            color: AppTheme.error, fontSize: 13, height: 1.5))),
      ]));

  List<Assignment> _filteredAssignments(DataEntryViewModel vm) {
    final q = _assignSearch.trim().toLowerCase();
    if (q.isEmpty) return vm.assignments;
    final roomNameById = { for (final r in vm.rooms) r.id: r.name };
    return vm.assignments.where((a) {
      final roomName = a.roomId != null ? (roomNameById[a.roomId] ?? '') : '';
      return a.course.name.toLowerCase().contains(q) ||
          a.course.code.toLowerCase().contains(q) ||
          a.teacher.name.toLowerCase().contains(q) ||
          a.classModel.name.toLowerCase().contains(q) ||
          a.classModel.shortCode.toLowerCase().contains(q) ||
          roomName.toLowerCase().contains(q);
    }).toList();
  }

  Widget _listHeader(BuildContext ctx, DataEntryViewModel vm, AllocatorViewModel allocVm) {
    final filteredCount = _filteredAssignments(vm).length;
    final searchActive = _assignSearch.trim().isNotEmpty;
    return Row(children: [
        Text('Assignments', style: GoogleFonts.plusJakartaSans(
            fontSize: 17, fontWeight: FontWeight.w700, color: ctx._tp)),
        const SizedBox(width: 12),
        // Search bar — matches course, teacher, class/section, or room.
        Expanded(
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: ctx._dk ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: searchActive
                  ? AppTheme.accentViolet.withValues(alpha: .5)
                  : (ctx._dk ? AppTheme.divider : AppTheme.lightDivider)),
            ),
            child: Row(children: [
              Icon(Icons.search_rounded, size: 16,
                  color: searchActive ? AppTheme.accentViolet : ctx._ts),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _assignSearchCtrl,
                  onChanged: (v) => setState(() => _assignSearch = v),
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._tp),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search course, teacher, class, room…',
                    hintStyle: GoogleFonts.plusJakartaSans(fontSize: 12, color: ctx._ts),
                  ),
                ),
              ),
              if (searchActive)
                GestureDetector(
                  onTap: () { _assignSearchCtrl.clear(); setState(() => _assignSearch = ''); },
                  child: Icon(Icons.close_rounded, size: 16, color: ctx._ts),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        // Fix clashes button
        GestureDetector(
          onTap: (allocVm.isGenerating || ctx.watch<SettingsViewModel>().scheduleLocked) ? null : () => _doFixClashes(vm, allocVm),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.error.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.error.withValues(alpha: .4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.auto_fix_high_rounded,
                  color: ctx.watch<SettingsViewModel>().scheduleLocked ? AppTheme.error.withValues(alpha: 0.5) : AppTheme.error, size: 14),
              const SizedBox(width: 5),
              Text('Fix Clashes', style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, color: ctx.watch<SettingsViewModel>().scheduleLocked ? AppTheme.error.withValues(alpha: 0.5) : AppTheme.error, fontSize: 11)),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: AppTheme.accentViolet.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.accentViolet.withValues(alpha: .3))),
            child: Text(
                searchActive ? '$filteredCount / ${vm.assignments.length}' : '${vm.assignments.length} total',
                style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, color: AppTheme.accentViolet, fontSize: 11))),
      ]);
  }

  /// Searches for a chain of relocations (any length — each card moves at
  /// most once, and the wall-clock budget is the real limit) that opens a
  /// full slot for the pending course+teacher+class pick. Every step is
  /// verified clash-free in simulation (teacher, class, electives,
  /// cross-level clock overlap); nothing is changed until the user confirms
  /// in [_offerMakeSpace]. Rooms are not checked — the matrix clash counter
  /// ignores rooms too.
  Future<_MsPlan?> _findMakeSpace(
      DataEntryViewModel dataVm, int workingDaysCount) async {
    if (_course == null || _class == null || _teacher == null) return null;
    // ponytail: hard 3s wall clock cap — the backtracking search is
    // exponential in dense timetables and runs on the UI thread; move to an
    // isolate if partial results ever matter.
    final deadline = Stopwatch()..start();
    bool outOfTime() => deadline.elapsedMilliseconds > 3000;
    final needed = _course!.creditHours;
    final allDays = List.generate(workingDaysCount, (i) => i + 1);
    final combinedIds = dataVm.combinedRules.map((r) => r.courseId).toSet();
    final newAllowed =
        dataVm.effectiveAllowedSlotsForClass(_class!.id, workingDaysCount);
    final slots = dataVm.timeSlots
        .where((t) =>
            t.level == _class!.level &&
            (newAllowed == null || newAllowed.contains(t.id)))
        .toList()
      ..sort((a, b) => a.period.compareTo(b.period));

    // Simulated positions: cardId -> relocated slot. A card moves at most
    // once per plan, which also bounds the recursion.
    final overrides = <String, ({TimeSlot slot, List<int> days})>{};
    final moves = <_MsMove>[];

    // Current move budget — raised one step at a time by the iterative
    // deepening driver at the bottom, so cheap plans at any period are found
    // before deep dead-end subtrees can eat the time budget.
    var maxMoves = 1;

    String effSlotId(Assignment a) => overrides[a.id]?.slot.id ?? a.timeSlotId;
    List<int> effDays(Assignment a) => overrides[a.id]?.days ?? a.occupiedSlots;

    TimeSlot? slotById(String id) {
      for (final s in dataVm.timeSlots) {
        if (s.id == id) return s;
      }
      return null;
    }

    bool electiveBlocks(String slotId, int day,
            {String? classId, String? teacherId}) =>
        dataVm.electiveGroups.any((eg) =>
            eg.timeSlotId.isNotEmpty &&
            dataVm.electiveOccupiedDays(eg).contains(day) &&
            ((classId != null && eg.classIds.contains(classId)) ||
                (teacherId != null &&
                    eg.entries.any((e) => e.teacherId == teacherId))) &&
            _slotsOverlap(dataVm, eg.timeSlotId, slotId));

    Iterable<Assignment> cardsAt(String slotId, int day,
            {String? classId,
            String? teacherId,
            String? roomId,
            String? excludeId}) =>
        dataVm.assignments.where((a) =>
            a.id != excludeId &&
            (classId == null || a.classModel.id == classId) &&
            (teacherId == null || a.teacher.id == teacherId) &&
            (roomId == null || (a.hasRoom && a.roomId == roomId)) &&
            effDays(a).contains(day) &&
            _slotsOverlap(dataVm, effSlotId(a), slotId));

    bool movable(Assignment a) =>
        !a.id.startsWith('elec_') &&
        !combinedIds.contains(a.course.id) &&
        !overrides.containsKey(a.id);

    // Relocates card b to any slot where it fits, recursively displacing
    // cards that stand in the way (within the move budget). `avoid` is the
    // slot being opened for the new course: cards sharing its teacher or
    // class must not land on a clock-overlapping slot. Backtracks cleanly.
    bool relocate(Assignment b, TimeSlot avoid) {
      if (outOfTime()) return false;
      final from = slotById(b.timeSlotId);
      if (from == null) return false;
      final sharesTarget =
          b.teacher.id == _teacher!.id || b.classModel.id == _class!.id;
      // Shift policy: a displaced card may only land in its class's allowed
      // periods (null = unrestricted).
      final shiftAllowed = dataVm.effectiveAllowedSlotsForClass(
          b.classModel.id, workingDaysCount);
      final targets = dataVm.timeSlots
          .where((t) =>
              t.level == b.classModel.level &&
              (shiftAllowed == null || shiftAllowed.contains(t.id)))
          .toList()
        ..sort((a, b2) => a.period.compareTo(b2.period));
      // Candidate day windows: full-week cards keep their days; partial
      // cards may also slide to any other contiguous window of equal length.
      final n = b.occupiedSlots.length;
      final daySets = n >= workingDaysCount
          ? <List<int>>[b.occupiedSlots]
          : <List<int>>[
              for (var s = 1; s + n - 1 <= workingDaysCount; s++)
                List.generate(n, (i) => s + i)
            ];
      for (final pt in targets) {
        if (sharesTarget && _slotsOverlap(dataVm, pt.id, avoid.id)) continue;
        for (final ds in daySets) {
          if (outOfTime()) return false;
          if (pt.id == effSlotId(b) && listEquals(ds, effDays(b))) continue;
          var electiveHit = false;
          for (final d in ds) {
            if (electiveBlocks(pt.id, d, classId: b.classModel.id) ||
                electiveBlocks(pt.id, d, teacherId: b.teacher.id)) {
              electiveHit = true;
              break;
            }
          }
          if (electiveHit) continue;
          final conflicts = <String, Assignment>{};
          for (final d in ds) {
            for (final c in cardsAt(pt.id, d,
                classId: b.classModel.id, excludeId: b.id)) {
              conflicts[c.id] = c;
            }
            for (final c in cardsAt(pt.id, d,
                teacherId: b.teacher.id, excludeId: b.id)) {
              conflicts[c.id] = c;
            }
            if (b.hasRoom) {
              for (final c in cardsAt(pt.id, d,
                  roomId: b.roomId, excludeId: b.id)) {
                conflicts[c.id] = c;
              }
            }
          }
          if (conflicts.isEmpty) {
            if (moves.length >= maxMoves) return false;
            overrides[b.id] = (slot: pt, days: ds);
            moves.add((card: b, from: from, to: pt, days: ds));
            return true;
          }
          // Chain: displace every conflicting card first, then take the slot.
          if (moves.length + conflicts.length + 1 > maxMoves) continue;
          if (conflicts.values.any((c) => !movable(c))) continue;
          final savedOverrides =
              Map<String, ({TimeSlot slot, List<int> days})>.of(overrides);
          final savedLen = moves.length;
          var ok = true;
          for (final c in conflicts.values) {
            if (!relocate(c, avoid)) {
              ok = false;
              break;
            }
          }
          if (ok) {
            // A displaced card may itself have landed here — re-check.
            var still = false;
            for (final d in ds) {
              if (cardsAt(pt.id, d, classId: b.classModel.id, excludeId: b.id)
                      .isNotEmpty ||
                  cardsAt(pt.id, d, teacherId: b.teacher.id, excludeId: b.id)
                      .isNotEmpty ||
                  (b.hasRoom &&
                      cardsAt(pt.id, d, roomId: b.roomId, excludeId: b.id)
                          .isNotEmpty)) {
                still = true;
                break;
              }
            }
            if (!still && moves.length < maxMoves) {
              overrides[b.id] = (slot: pt, days: ds);
              moves.add((card: b, from: from, to: pt, days: ds));
              return true;
            }
          }
          overrides
            ..clear()
            ..addAll(savedOverrides);
          moves.removeRange(savedLen, moves.length);
        }
      }
      return false;
    }

    Future<_MsPlan?> attemptPass() async {
    for (final ps in slots) {
      // Yield to the event loop so the progress dialog keeps painting.
      await Future<void>.delayed(Duration.zero);
      if (outOfTime()) return null;
      // Day universe not reserved by electives for either party
      final u = allDays
          .where((d) =>
              !electiveBlocks(ps.id, d, classId: _class!.id) &&
              !electiveBlocks(ps.id, d, teacherId: _teacher!.id))
          .toList();
      if (u.length < needed) continue;
      overrides.clear();
      moves.clear();
      final blockers = <String, Assignment>{};
      for (final d in u) {
        for (final a in cardsAt(ps.id, d, classId: _class!.id)) {
          blockers[a.id] = a;
        }
        for (final a in cardsAt(ps.id, d, teacherId: _teacher!.id)) {
          blockers[a.id] = a;
        }
      }
      if (blockers.isEmpty || blockers.length > maxMoves) continue;
      if (blockers.values.any((b) => !movable(b))) continue;
      var ok = true;
      for (final b in blockers.values) {
        // An earlier blocker's chain may have relocated this one already —
        // moving a card twice would corrupt the plan (its id changes after
        // the first applied move).
        if (overrides.containsKey(b.id)) continue;
        if (!relocate(b, ps)) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      // Final net check in the simulated state: the slot must really be
      // open for the required number of days.
      final freeAfter = u
          .where((d) =>
              cardsAt(ps.id, d, classId: _class!.id).isEmpty &&
              cardsAt(ps.id, d, teacherId: _teacher!.id).isEmpty)
          .toList();
      if (freeAfter.length < needed) continue;
      return (
        moves: List<_MsMove>.of(moves),
        place: ps,
        days: freeAfter.take(needed).toList()
      );
    }
    return null;
    }

    // Iterative deepening: shallow plans anywhere beat deep ones somewhere.
    // Ceiling = every card moved once; in practice the 3s budget stops first.
    final moveCeiling = dataVm.assignments.length;
    for (var cap = 1; cap <= moveCeiling; cap++) {
      maxMoves = cap;
      final plan = await attemptPass();
      if (plan != null) return plan;
      if (outOfTime()) break;
    }
    return null;
  }

  void _offerMakeSpace(
      DataEntryViewModel dataVm, AllocatorViewModel allocVm, _MsPlan m) {
    final steps = [
      for (var i = 0; i < m.moves.length; i++)
        '${i + 1}. Move ${m.moves[i].card.course.name} '
            '(${m.moves[i].card.teacher.name} → ${m.moves[i].card.classModel.shortCode}) '
            'from P${m.moves[i].from.period} (days ${m.moves[i].card.occupiedSlots.join(', ')}) '
            'to P${m.moves[i].to.period} (days ${m.moves[i].days.join(', ')})'
            '${m.moves[i].card.autoAssigned ? '' : '  [manual card]'}'
    ].join('\n');
    showDialog(
        context: context,
        builder: (dCtx) => AlertDialog(
              title: Text('Make space?',
                  style:
                      GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800)),
              content: SingleChildScrollView(
                child: Text(
                    'No slot fits ${_course!.name} for ${_class!.shortCode} directly, '
                    'but ${m.moves.length == 1 ? 'one move opens' : '${m.moves.length} moves open'} space:\n\n'
                    '$steps\n\n'
                    'Then ${_course!.name} takes P${m.place.period} on days ${m.days.join(', ')}.\n\n'
                    'Nothing changes unless you apply.',
                    style: GoogleFonts.plusJakartaSans(fontSize: 13)),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dCtx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(dCtx);
                      dataVm.snapshotForUndo(
                          'Make space: ${_course!.name} for ${_class!.shortCode}');
                      // Every card must still exist before anything moves.
                      for (final mv in m.moves) {
                        if (dataVm.assignments
                                .where((a) => a.id == mv.card.id)
                                .firstOrNull ==
                            null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Not applied: a card changed in the meantime.')));
                          return;
                        }
                      }
                      for (final mv in m.moves) {
                        final cur = dataVm.assignments
                            .where((a) => a.id == mv.card.id)
                            .first;
                        dataVm.removeAssignment(cur.id);
                        dataVm.addAssignment(
                            teacher: cur.teacher,
                            course: cur.course,
                            classModel: cur.classModel,
                            startSlot: mv.days.first,
                            duration: mv.days.length,
                            timeSlotId: mv.to.id,
                            customDays: const [],
                            roomId: cur.roomId,
                            autoAssigned: cur.autoAssigned);
                      }
                      // Edit flow restores the original card on failure —
                      // drop it or the retry below dies on its own
                      // duplicate-course check.
                      final dup = dataVm.assignments
                          .where((a) =>
                              (a.course.id == _course!.id ||
                                  a.course.code.trim().toUpperCase() ==
                                      _course!.code.trim().toUpperCase()) &&
                              a.classModel.id == _class!.id)
                          .firstOrNull;
                      if (dup != null) dataVm.removeAssignment(dup.id);
                      // Retry the original add — the space is now open, and
                      // _doAssign re-verifies everything honestly.
                      _doAssign(dataVm, allocVm);
                    },
                    child: const Text('Apply & Assign')),
              ],
            ));
  }

  /// Last resort, offered only after search proves no clash-free placement
  /// exists: assign at the least-conflicted slot anyway (creating real
  /// clashes) so CSP/GA can rearrange the whole timetable to resolve them.
  /// Applied only on explicit user confirmation.
  void _offerForceAssign(DataEntryViewModel dataVm, int needed) {
    if (_course == null || _class == null || _teacher == null) return;
    final wd = context.read<SettingsViewModel>().workingDays;
    final allDays = List.generate(wd, (i) => i + 1);
    final slots = dataVm.timeSlots
        .where((t) => t.level == _class!.level)
        .toList()
      ..sort((a, b) => a.period.compareTo(b.period));
    if (slots.isEmpty) return;
    // Exact busy check: real cards by clock overlap (cross-level included)
    // plus elective-group day blocks — same rules the solvers enforce.
    bool blocked(String slotId, int d, {String? cId, String? tId}) =>
        dataVm.assignments.any((a) =>
            ((cId != null && a.classModel.id == cId) ||
                (tId != null && a.teacher.id == tId)) &&
            a.occupiedSlots.contains(d) &&
            _slotsOverlap(dataVm, a.timeSlotId, slotId)) ||
        dataVm.electiveGroups.any((eg) =>
            eg.timeSlotId.isNotEmpty &&
            dataVm.electiveOccupiedDays(eg).contains(d) &&
            ((cId != null && eg.classIds.contains(cId)) ||
                (tId != null &&
                    eg.entries.any((e) => e.teacherId == tId))) &&
            _slotsOverlap(dataVm, eg.timeSlotId, slotId));
    // Slot where the class is free the most days; teacher-free days break ties.
    TimeSlot? best;
    var bestC = -1, bestT = -1;
    for (final ts in slots) {
      final cFree = allDays
          .where((d) => !blocked(ts.id, d, cId: _class!.id))
          .length;
      final tFree = allDays
          .where((d) => !blocked(ts.id, d, tId: _teacher!.id))
          .length;
      if (cFree > bestC || (cFree == bestC && tFree > bestT)) {
        best = ts;
        bestC = cFree;
        bestT = tFree;
      }
    }
    final place = best!;
    // Contiguous day window with the fewest conflicts.
    var s0 = 1, bestScore = -1;
    for (var s = 1; s + needed - 1 <= wd; s++) {
      final win = List.generate(needed, (i) => s + i);
      final score = win
          .where((d) =>
              !blocked(place.id, d, cId: _class!.id) &&
              !blocked(place.id, d, tId: _teacher!.id))
          .length;
      if (score > bestScore) {
        bestScore = score;
        s0 = s;
      }
    }
    final days = List.generate(needed, (i) => s0 + i);
    final clashing = needed - bestScore;
    showDialog(
        context: context,
        builder: (dCtx) => AlertDialog(
              title: Text('Assign with clash?',
                  style:
                      GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800)),
              content: Text(
                  'No clash-free placement or rearrangement exists right now.\n\n'
                  'Force-assign ${_course!.name} → ${_teacher!.name} for '
                  '${_class!.shortCode} at P${place.period} on days ${days.join(', ')}?\n\n'
                  'This creates $clashing clashing day${clashing == 1 ? '' : 's'} '
                  'on purpose. Run CSP or GA right after — with everything '
                  'movable they can rearrange other cards to clear it.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 13)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dCtx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(dCtx);
                      dataVm.snapshotForUndo(
                          'Force-assign: ${_course!.name} for ${_class!.shortCode}');
                      // Edit flow restores the original card on failure —
                      // drop it so the force-add can't create a duplicate.
                      final dup = dataVm.assignments
                          .where((a) =>
                              (a.course.id == _course!.id ||
                                  a.course.code.trim().toUpperCase() ==
                                      _course!.code.trim().toUpperCase()) &&
                              a.classModel.id == _class!.id)
                          .firstOrNull;
                      if (dup != null) dataVm.removeAssignment(dup.id);
                      dataVm.addAssignment(
                          teacher: _teacher!,
                          course: _course!,
                          classModel: _class!,
                          startSlot: days.first,
                          duration: needed,
                          timeSlotId: place.id,
                          customDays: const [],
                          autoAssigned: true);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              'Assigned with clash at P${place.period}. '
                              'Run CSP or GA now to resolve it.',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white)),
                          backgroundColor: Colors.orange.shade800,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          margin: const EdgeInsets.all(16),
                          duration: const Duration(seconds: 7)));
                    },
                    child: const Text('Assign with clash')),
              ],
            ));
  }

  Future<void> _doAssign(
      DataEntryViewModel dataVm, AllocatorViewModel allocVm) async {
    if (_checkLock()) { _restoreEditBackupIfAny(dataVm); return; }
    if (_course != null && _class != null && _teacher != null) {
      // Match by id OR code: duplicate course records (same code, different
      // ids) must still count as the same course here.
      final existingAssignment = dataVm.assignments.where((a) =>
      (a.course.id == _course!.id ||
              a.course.code.trim().toUpperCase() == _course!.code.trim().toUpperCase()) &&
          a.classModel.id == _class!.id).firstOrNull;

      if (existingAssignment != null) {
        final isSameTeacher = existingAssignment.teacher.id == _teacher!.id;
        final msg = isSameTeacher
            ? "You cannot assign ${_course!.code} to ${_teacher!.name} and to ${_class!.shortCode} twice"
            : "${_course!.code} is already assigned to ${existingAssignment.teacher.name} for ${_class!.shortCode}";

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg,
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }
    }

    List<int> finalDays;
    bool daysAuto = false;
    if (_autoDays) {
      final validSlots = dataVm.timeSlots.where((t) => _class == null || t.level == _class!.level).toList();
      if (validSlots.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Cannot Auto-Assign: No time slots configured for ${_class!.level.name} level. Please add time slots in Manage Data.",
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }
      final r = _autoFindResult(dataVm);
      final needed = _course?.creditHours ?? 3;
      if (r == null || r.length < needed) {
        // One verified move can sometimes open a whole slot — offer it.
        // Applied only when the user confirms in the dialog.
        showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
                  content: Row(children: [
                    const CircularProgressIndicator(),
                    const SizedBox(width: 20),
                    Expanded(
                        child: Text('Finding a rearrangement…',
                            style: GoogleFonts.plusJakartaSans(
                                fontWeight: FontWeight.w600))),
                  ]),
                ));
        final ms = await _findMakeSpace(
            dataVm, context.read<SettingsViewModel>().workingDays);
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        if (ms != null) {
          _offerMakeSpace(dataVm, allocVm, ms);
          _restoreEditBackupIfAny(dataVm);
          return;
        }
        final found = r?.length ?? 0;
        // allDays local to _doAssign (mirrors the one in _autoFindResult)
        final workingDays = context.read<SettingsViewModel>().workingDays;
        final allDaysLocal = List.generate(workingDays, (i) => i + 1);
        // Build a per-slot analysis to give a meaningful error message
        final slots = validSlots;
        String hint = '';
        if (slots.isNotEmpty) {
          String? bestSlotLabel;
          int bestTeacherFree = 0;
          int bestClassFree = 0;
          for (final ts in slots) {
            final tFree = allDaysLocal.where((d) => !dataVm.occupiedTimeSlotIdsForTeacher(_teacher!.id, d).contains(ts.id)).length;
            final cFree = _class == null ? allDaysLocal.length : allDaysLocal.where((d) => !dataVm.occupiedTimeSlotIdsForClass(_class!.id, d).contains(ts.id)).length;
            final combined = allDaysLocal.where((d) =>
            !dataVm.occupiedTimeSlotIdsForTeacher(_teacher!.id, d).contains(ts.id) &&
                (_class == null || !dataVm.occupiedTimeSlotIdsForClass(_class!.id, d).contains(ts.id))).length;
            if (combined > found || (combined == found && tFree > bestTeacherFree)) {
              bestSlotLabel = ts.shortLabel;
              bestTeacherFree = tFree;
              bestClassFree = cFree;
            }
          }
          if (bestSlotLabel != null) {
            if (bestTeacherFree < needed) {
              hint = ' ${_teacher!.name} is teaching another class in all available $bestSlotLabel slots.';
            } else if (bestClassFree < needed) {
              hint = ' ${_class?.shortCode ?? 'This class'} already has courses filling $bestSlotLabel.';
            }
          }
        }
        final msg = found == 0
            ? 'Cannot schedule ${_course!.code}: No time slot exists where both ${_teacher!.name} and ${_class?.shortCode ?? 'the class'} are free for all $needed days.$hint'
            : '${_teacher!.name} and ${_class?.shortCode ?? 'class'} only share $found free day${found == 1 ? '' : 's'}, but ${_course!.creditHours} are needed for ${_course!.code}.$hint';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg,
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 7)));
        // Last resort: user may force the assignment in with a clash and
        // let CSP/GA rearrange the rest of the timetable to clear it.
        _offerForceAssign(dataVm, needed);
        _restoreEditBackupIfAny(dataVm);
        return;
      }
      finalDays = r;
      daysAuto  = true;
    } else {
      finalDays = _selectedDays.toList()..sort();
    }
    String finalPeriod;
    bool periodAuto = false;
    if (_autoPeriod) {
      final validSlotsForClass = dataVm.timeSlots
          .where((t) => _class == null || t.level == _class!.level)
          .toList();
      // Pick first slot where the teacher AND the class are both free on all finalDays
      // Pick first slot where the teacher AND the class are both free on all finalDays
      // Uses clock-time overlap check so cross-level conflicts are detected correctly.
      final fp = validSlotsForClass.isEmpty
          ? null
          : validSlotsForClass.where((ts) => finalDays.every((day) {
        final teacherBusy = dataVm.assignments.any((a) {
          if (a.teacher.id != _teacher!.id) return false;
          if (!a.occupiedSlots.contains(day)) return false;
          if (a.timeSlotId == ts.id) return true;
          final existSlot = dataVm.timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
          if (existSlot == null) return false;
          int pm(String t) { final p = t.split(':'); return (int.tryParse(p[0]) ?? 0)*60+(int.tryParse(p[1]) ?? 0); }
          return pm(ts.startTime) < pm(existSlot.endTime) && pm(existSlot.startTime) < pm(ts.endTime);
        });
        final classBusy = _class != null &&
            dataVm.occupiedTimeSlotIdsForClass(_class!.id, day).contains(ts.id);
        // Elective-reserved slot (teacher teaches in the group, or the class
        // attends it)? Only the elective's own days block — leftover days
        // of the period are proposable.
        final electiveBusy = dataVm.electiveGroups.any((eg) =>
            eg.timeSlotId.isNotEmpty &&
            dataVm.electiveOccupiedDays(eg).contains(day) &&
            (eg.entries.any((e) => e.teacherId == _teacher!.id) ||
                (_class != null && eg.classIds.contains(_class!.id))) &&
            _slotsOverlap(dataVm, eg.timeSlotId, ts.id));
        return !teacherBusy && !classBusy && !electiveBusy;
      })).firstOrNull;
      if (fp == null) {
        // No fallback to an occupied slot: the save guard would reject it
        // anyway. Tell the user honestly that nothing is free.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'No free period for ${_course!.code}: on the chosen days every '
                '${_class!.level.name} slot clashes with existing courses or an '
                'elective block. Pick different days, or free space first '
                '(move a course, or re-run the scheduler).',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 7)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }
      finalPeriod = fp.id;
      periodAuto  = true;
    } else {
      finalPeriod = _timeSlotId!;
    }
    final sorted   = finalDays..sort();
    final isConsec = sorted.length >= 2 && sorted.last - sorted.first == sorted.length - 1;
    final startSlot = sorted.first;
    final duration  = sorted.length;
    final custom    = isConsec ? <int>[] : sorted;

    // Room is assigned separately via the Room Allocation box below — new
    // assignments start room-less; editing preserves whatever room it
    // already had (see _populateFormForEdit).
    final finalRoomId = _roomId;

    // ── Hard class-clash guard ─────────────────────────────────────────────
    // Prevent saving if the class already has ANY course in the chosen
    // time slot on ANY of the chosen days (would create a timetable clash).
    if (_class != null) {
      final clashDays = sorted.where((day) =>
          dataVm.occupiedTimeSlotIdsForClass(_class!.id, day).contains(finalPeriod)).toList();
      if (clashDays.isNotEmpty) {
        final dayNames = clashDays.map((d) => _dayShort[d - 1]).join(', ');
        final ts = dataVm.timeSlots.where((t) => t.id == finalPeriod).firstOrNull;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Class clash! ${_class!.shortCode} already has a course in '
                    '${ts?.label ?? finalPeriod} on $dayNames. '
                    'Choose different days or a different period.',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 5)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }
    }

    // ── Combined-course check ──────────────────────────────────────────────
    final combinedRule = dataVm.combinedRules
        .where((r) => r.courseId == _course!.id)
        .firstOrNull;

    // DEBUG
    debugPrint('=== COMBINED DEBUG ===');
    debugPrint('Course id=${_course!.id} code=${_course!.code}');
    debugPrint('All rules (${dataVm.combinedRules.length}): ${dataVm.combinedRules.map((r) => "courseId=${r.courseId} classIds=${r.classIds}").join(" | ")}');
    debugPrint('Matched rule: $combinedRule  courseId=${combinedRule?.courseId}  classIds=${combinedRule?.classIds}');

    final List<ClassModel> targetClasses = [_class!];
    if (combinedRule != null) {
      for (final cid in combinedRule.classIds) {
        if (cid == _class!.id) continue;
        final sibling = dataVm.classes.where((c) => c.id == cid).firstOrNull;
        debugPrint('  Sibling cid=$cid found=${sibling?.name}');
        if (sibling != null) targetClasses.add(sibling);
      }
    }
    debugPrint('targetClasses: ${targetClasses.map((c) => c.shortCode).join(", ")}');
    debugPrint('=== END COMBINED DEBUG ===');

    // ── Teacher / elective / room clash guard ──────────────────────────────
    // Same strictness as elective save: reject clock-overlapping conflicts
    // (cross-level included) BEFORE anything is written, instead of saving a
    // pinned assignment the scheduler can never fix.
    {
      int pm(String t) { final p = t.split(':'); return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0); }
      final newSlot = dataVm.timeSlots.where((t) => t.id == finalPeriod).firstOrNull;
      bool overlapsSlot(String otherId) {
        if (otherId == finalPeriod) return true;
        final o = dataVm.timeSlots.where((t) => t.id == otherId).firstOrNull;
        if (newSlot == null || o == null) return false;
        return pm(newSlot.startTime) < pm(o.endTime) && pm(o.startTime) < pm(newSlot.endTime);
      }
      String slotLabel(String id) =>
          dataVm.timeSlots.where((t) => t.id == id).firstOrNull?.shortLabel ?? id;
      final targetClassIds = targetClasses.map((c) => c.id).toSet();
      // Records this save is about to replace (edit or combined-sibling
      // re-create) must not count as conflicts.
      bool replacedByThisSave(Assignment a) =>
          (a.course.id == _course!.id ||
              a.course.code.trim().toUpperCase() == _course!.code.trim().toUpperCase()) &&
          targetClassIds.contains(a.classModel.id);

      String err = '';
      for (final a in dataVm.assignments) {
        if (replacedByThisSave(a)) continue;
        if (!sorted.any(a.occupiedSlots.contains)) continue;
        if (!overlapsSlot(a.timeSlotId)) continue;
        if (a.teacher.id == _teacher!.id) {
          err = 'Teacher clash! ${_teacher!.name} already teaches ${a.course.code} '
              'to ${a.classModel.shortCode} in ${slotLabel(a.timeSlotId)} at an '
              'overlapping time. Move or remove that assignment first.';
        } else if (finalRoomId != null && a.roomId == finalRoomId) {
          err = 'Room clash! That room is taken by ${a.course.code} '
              '(${a.classModel.shortCode}) in ${slotLabel(a.timeSlotId)} at an '
              'overlapping time. Move or remove that assignment first.';
        }
        if (err.isNotEmpty) break;
      }
      if (err.isEmpty) {
        for (final eg in dataVm.electiveGroups) {
          if (!overlapsSlot(eg.timeSlotId)) continue;
          // Electives only occupy their first N days — the leftover days of
          // that period are free for regular allocations.
          if (!sorted.any(dataVm.electiveOccupiedDays(eg).contains)) continue;
          if (eg.entries.any((e) => e.teacherId == _teacher!.id)) {
            err = 'Teacher clash! ${_teacher!.name} teaches in the elective group '
                'at ${slotLabel(eg.timeSlotId)}, which overlaps this time.';
          } else if (finalRoomId != null &&
              eg.entries.any((e) => e.roomId == finalRoomId)) {
            err = 'Room clash! That room is used by the elective group '
                'at ${slotLabel(eg.timeSlotId)}, which overlaps this time.';
          } else {
            final blocked =
                targetClasses.where((c) => eg.classIds.contains(c.id)).firstOrNull;
            if (blocked != null) {
              err = 'Elective clash! ${blocked.shortCode} has its elective block '
                  'at ${slotLabel(eg.timeSlotId)}, which overlaps this time.';
            }
          }
          if (err.isNotEmpty) break;
        }
      }
      if (err.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(err,
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16), duration: const Duration(seconds: 6)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }
    }

    // Validate every target class, build final list of classes that need new assignments
    final List<ClassModel> classesToCreate = [];
    for (final cls in targetClasses) {
      final isPrimary = cls.id == _class!.id;
      final existingForClass = dataVm.assignments.where((a) =>
      (a.course.id == _course!.id ||
              a.course.code.trim().toUpperCase() == _course!.code.trim().toUpperCase()) &&
          a.classModel.id == cls.id).firstOrNull;

      if (existingForClass != null) {
        if (isPrimary) {
          // Primary already has this course — hard error
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('${_course!.code} is already assigned to ${cls.shortCode}. Remove it first.',
                  style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
              backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.all(16), duration: const Duration(seconds: 5)));
          _restoreEditBackupIfAny(dataVm);
          return;
        } else {
          // Sibling already has course — remove old and re-create in the new slot/days
          // so it stays in sync with the primary assignment
          dataVm.removeAssignment(existingForClass.id);
        }
      }

      // Clash check (for this class in the chosen slot on the chosen days)
      // Re-read after possible removal above
      final clashDays = sorted.where((day) =>
          dataVm.occupiedTimeSlotIdsForClass(cls.id, day).contains(finalPeriod)).toList();
      if (clashDays.isNotEmpty) {
        final dayNames = clashDays.map((d) => _dayShort[d - 1]).join(', ');
        final ts = dataVm.timeSlots.where((t) => t.id == finalPeriod).firstOrNull;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                isPrimary
                    ? 'Class clash! ${cls.shortCode} already has a course in '
                    '${ts?.label ?? finalPeriod} on $dayNames. '
                    'Choose different days or a different period.'
                    : 'Combined class clash! ${cls.shortCode} already has a different course in '
                    '${ts?.label ?? finalPeriod} on $dayNames. '
                    'Free that slot in ${cls.shortCode} first.',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16), duration: const Duration(seconds: 6)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }

      // ── Elective-duplicate check ─────────────────────────────────────────
      // Block if this course is already covered by an elective group for this class.
      final electiveDup = dataVm.electiveGroups.where((eg) =>
          eg.classIds.contains(cls.id) &&
          eg.entries.any((e) => e.courseId == _course!.id)).firstOrNull;
      if (electiveDup != null) {
        final tsLabel = dataVm.timeSlots
            .where((t) => t.id == electiveDup.timeSlotId).firstOrNull?.label
            ?? electiveDup.timeSlotId;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${_course!.code} is already allocated to ${cls.shortCode} '
                'in the Elective Group at $tsLabel. '
                'Remove it from the elective first.',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 6)));
        _restoreEditBackupIfAny(dataVm);
        return;
      }

      classesToCreate.add(cls);
    }

    // All clear — save assignment for every class that needs it
    for (final cls in classesToCreate) {
      dataVm.addAssignment(
        teacher: _teacher!, course: _course!, classModel: cls,
        startSlot: startSlot, duration: duration,
        timeSlotId: finalPeriod, customDays: custom,
        roomId: finalRoomId,
        // If the days are non-consecutive, force it to be locked (manual) 
        // because the GA cannot natively mutate into non-consecutive blocks.
        autoAssigned: daysAuto && periodAuto && isConsec,
      );
    }

    final dayStr = sorted.map((d) => _dayShort[d-1]).join(', ');
    final ts = dataVm.timeSlots.where((t) => t.id == finalPeriod).firstOrNull;
    final combinedNote = targetClasses.length > 1
        ? '  ✦ Combined: ${targetClasses.map((c) => c.shortCode).join(' + ')}'
        : '';

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${_course!.code} → ${_teacher!.name}  -  $dayStr'
            '${ts != null ? "  -  ${ts.label}" : ""}'
            '${daysAuto && periodAuto ? "  Auto" : ""}'
            '$combinedNote',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        backgroundColor: const Color(0xFF1E293B), behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16)));

    // Successful save — the edited assignment (if any) has been recreated,
    // so there's nothing left to roll back.
    _editBackup = null;

    setState(() {
      _teacher = null; _course = null; _class = null;
      _selectedDays = {}; _timeSlotId = null;
      _autoDays = true; _autoPeriod = true;
      _roomId = null;
      _showAdvanced = false;
    });
  }

  Future<void> _doFixClashes(DataEntryViewModel dataVm, AllocatorViewModel allocVm) async {
    if (_checkLock() || _isFixingClashes) return;
    setState(() => _isFixingClashes = true);
    
    try {
      await Future.delayed(Duration.zero); // yield so UI can update and ignore subsequent taps
      final workingDays = context.read<SettingsViewModel>().workingDays;
      final fixes = dataVm.fixTeacherClashes(workingDays: workingDays);
      if (fixes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('No clashes found! Timetable is clean.',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: const Color(0xFF0D9488),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16)));
        return;
      }
      // Refresh schedule view
      allocVm.validateAndApply(dataVm.assignments, dataVm.timeSlots, combinedRules: dataVm.combinedRules, rooms: dataVm.rooms);
      
      if (!mounted) return;
      // Show what was fixed
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: [
          Icon(Icons.auto_fix_high_rounded, color: AppTheme.error, size: 22),
          const SizedBox(width: 10),
          Text('${fixes.length} Clash${fixes.length > 1 ? 'es' : ''} Fixed',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 17)),
        ]),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('The following assignments were automatically adjusted:',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 12),
                ...fixes.map((msg) {
                  final unresolved = msg.contains('Could not relocate');
                  return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                        unresolved ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                        color: unresolved ? AppTheme.accentAmber : const Color(0xFF0D9488),
                        size: 15),
                    const SizedBox(width: 8),
                    Expanded(child: Text(msg,
                        style: GoogleFonts.plusJakartaSans(fontSize: 12))),
                  ]),
                  );
                }),
                const SizedBox(height: 8),
                Text('Tip: anything still marked "Could not relocate" needs a manual fix — try Transfers & Swap.',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Done', style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, color: AppTheme.accentCyan)),
          ),
        ],
      ),
    );
    } finally {
      if (mounted) setState(() => _isFixingClashes = false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Day Grid
// ─────────────────────────────────────────────────────────────────────────────
class _DayGrid extends StatelessWidget {
  final Set<int> occupiedDays;
  final Set<int> selectedDays;
  final Color    color;
  final bool     readOnly;
  final void Function(int day)? onToggle;
  final int      workingDays;

  static const _short = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  const _DayGrid({required this.occupiedDays, required this.selectedDays,
    required this.color, required this.readOnly, required this.onToggle, required this.workingDays});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final freeBg = isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9);
    final freeBd = isDark ? AppTheme.divider : AppTheme.lightDivider;

    return Row(
      children: List.generate(workingDays, (i) {
        final day  = i + 1;
        final occ  = occupiedDays.contains(day);
        final sel  = selectedDays.contains(day);
        final tap  = !readOnly && !occ;

        Color bg, border, numCol, lblCol;
        if (sel) {
          bg = color.withValues(alpha: .18); border = color;
          numCol = color; lblCol = color.withValues(alpha: .85);
        } else if (occ) {
          bg = AppTheme.error.withValues(alpha: .08); border = AppTheme.error.withValues(alpha: .4);
          numCol = AppTheme.error.withValues(alpha: .7); lblCol = AppTheme.error.withValues(alpha: .5);
        } else if (tap) {
          bg = freeBg; border = isDark ? color.withValues(alpha: .25) : freeBd;
          numCol = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
          lblCol = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;
        } else {
          bg = freeBg.withValues(alpha: .4); border = freeBd.withValues(alpha: .35);
          numCol = (isDark ? AppTheme.textMuted : AppTheme.lightTextMut).withValues(alpha: .4);
          lblCol = (isDark ? AppTheme.textMuted : AppTheme.lightTextMut).withValues(alpha: .3);
        }

        return Expanded(child: GestureDetector(
          onTap: tap ? () => onToggle?.call(day) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: EdgeInsets.only(right: i < 5 ? 5 : 0),
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: border, width: sel ? 1.5 : 1),
                boxShadow: sel ? [BoxShadow(color: color.withValues(alpha: .2),
                    blurRadius: 10, offset: const Offset(0,3))] : null),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('$day', style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800, fontSize: 17, color: numCol)),
              const SizedBox(height: 3),
              Text(_short[i], style: GoogleFonts.plusJakartaSans(
                  fontSize: 11, color: lblCol, fontWeight: FontWeight.w600)),
              const SizedBox(height: 5),
              Container(width: 6, height: 6, decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: occ ? AppTheme.error.withValues(alpha: .6)
                      : sel ? color
                      : tap ? color.withValues(alpha: .3)
                      : Colors.transparent)),
            ]),
          ),
        ));
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Period Grid
// ─────────────────────────────────────────────────────────────────────────────
class _PeriodGrid extends StatelessWidget {
  final List<TimeSlot> timeSlots;
  final String?        selectedId;
  final Set<String>    busyIds;
  final ValueChanged<String> onSelect;

  const _PeriodGrid({required this.timeSlots, required this.selectedId,
    required this.busyIds, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final freeBg = isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9);
    final freeBd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final freeTs = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final freeTm = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;

    return Wrap(
      spacing: 8, runSpacing: 8,
      children: timeSlots.map((ts) {
        final sel  = selectedId == ts.id;
        final busy = busyIds.contains(ts.id);
        final col  = busy ? AppTheme.error : AppTheme.accentViolet;
        return GestureDetector(
          onTap: busy ? null : () => onSelect(ts.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
                color: busy ? AppTheme.error.withValues(alpha: .07)
                    : sel ? col.withValues(alpha: .18) : freeBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: busy ? AppTheme.error.withValues(alpha: .35)
                        : sel ? col : freeBd,
                    width: sel ? 1.5 : 1),
                boxShadow: sel ? [BoxShadow(color: col.withValues(alpha: .22),
                    blurRadius: 8, offset: const Offset(0,2))] : null),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(ts.shortLabel, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800, fontSize: 13,
                  color: busy ? AppTheme.error.withValues(alpha: .55)
                      : sel ? col : freeTs)),
              const SizedBox(height: 3),
              Text('${ts.startTime}-${ts.endTime}', style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  color: busy ? AppTheme.error.withValues(alpha: .45)
                      : sel ? col.withValues(alpha: .8) : freeTm)),
              if (ts.hasFridayOverride)
                Text('Fri: ${ts.fridayLabel}', style: GoogleFonts.plusJakartaSans(
                    fontSize: 9, color: AppTheme.accentAmber.withValues(alpha: .8))),
              if (busy)
                Text('taken', style: GoogleFonts.plusJakartaSans(
                    fontSize: 9, fontWeight: FontWeight.w700,
                    color: AppTheme.error.withValues(alpha: .6))),
            ]),
          ),
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Room Grid — mirrors _PeriodGrid: busy rooms render red and can't be tapped
// ─────────────────────────────────────────────────────────────────────────────
class _RoomGrid extends StatelessWidget {
  final List<Room> rooms;
  final String? selectedId;
  final Set<String> busyIds;
  final ValueChanged<String> onSelect;

  const _RoomGrid({required this.rooms, required this.selectedId,
    required this.busyIds, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final freeBg = isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9);
    final freeBd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final freeTs = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final freeTm = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;

    // Ascending order — numeric room names sort by value (so "9" comes
    // before "11"), any legacy non-numeric names fall back to A-Z after.
    final sortedRooms = List<Room>.of(rooms)..sort((a, b) {
      final an = int.tryParse(a.name);
      final bn = int.tryParse(b.name);
      if (an != null && bn != null) return an.compareTo(bn);
      if (an != null) return -1;
      if (bn != null) return 1;
      return a.name.compareTo(b.name);
    });

    return Wrap(
      spacing: 8, runSpacing: 8,
      children: sortedRooms.map((r) {
        final sel  = selectedId == r.id;
        final busy = busyIds.contains(r.id);
        final col  = busy ? AppTheme.error
            : r.type == RoomType.room ? AppTheme.accentTeal
            : r.type == RoomType.hall ? AppTheme.accentViolet : AppTheme.accentAmber;
        return GestureDetector(
          onTap: busy ? null : () => onSelect(r.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
                color: busy ? AppTheme.error.withValues(alpha: .07)
                    : sel ? col.withValues(alpha: .18) : freeBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: busy ? AppTheme.error.withValues(alpha: .35)
                        : sel ? col : freeBd,
                    width: sel ? 1.5 : 1),
                boxShadow: sel && !busy ? [BoxShadow(color: col.withValues(alpha: .22),
                    blurRadius: 8, offset: const Offset(0,2))] : null),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(r.type == RoomType.hall ? Icons.holiday_village_rounded
                  : r.type == RoomType.other ? Icons.category_rounded
                  : Icons.meeting_room_rounded,
                  size: 14, color: busy ? AppTheme.error.withValues(alpha: .55)
                      : sel ? col : freeTm),
              const SizedBox(width: 7),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700, fontSize: 13,
                    color: busy ? AppTheme.error.withValues(alpha: .55)
                        : sel ? col : freeTs)),
                Text(busy ? 'occupied' : r.typeLabel, style: GoogleFonts.plusJakartaSans(
                    fontSize: 10, fontWeight: busy ? FontWeight.w700 : FontWeight.normal,
                    color: busy ? AppTheme.error.withValues(alpha: .6)
                        : sel ? col.withValues(alpha: .7) : freeTm)),
              ]),
              if (sel && !busy) ...[const SizedBox(width: 6), Icon(Icons.check_rounded, size: 14, color: col)],
            ]),
          ),
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Days Summary
// ─────────────────────────────────────────────────────────────────────────────
class _DaysSummary extends StatelessWidget {
  final Set<int> selectedDays;
  final int workingDays;
  static const _short = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  const _DaysSummary({required this.selectedDays, required this.workingDays});

  @override
  Widget build(BuildContext context) {
    final sorted = selectedDays.toList()..sort();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
          color: AppTheme.accentViolet.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accentViolet.withValues(alpha: .35), width: 1.5)),
      child: Row(children: [
        Icon(Icons.check_circle_outline_rounded, color: AppTheme.accentViolet, size: 18),
        const SizedBox(width: 10),
        Text('${sorted.length} day${sorted.length == 1 ? '' : 's'} selected  - ',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700,
                fontSize: 13, color: AppTheme.accentViolet)),
        Wrap(spacing: 4, children: sorted.map((d) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: AppTheme.accentViolet.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(6)),
            child: Text(_short[d-1], style: GoogleFonts.plusJakartaSans(
                fontSize: 11, fontWeight: FontWeight.w800,
                color: AppTheme.accentViolet)))).toList()),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mini Toggle (Auto / Manual)
// ─────────────────────────────────────────────────────────────────────────────
class _MiniToggle extends StatelessWidget {
  final String leftLabel, rightLabel, leftSub, rightSub;
  final bool isLeft;
  final Color leftColor, rightColor;
  final VoidCallback onLeft, onRight;

  const _MiniToggle({required this.leftLabel, required this.rightLabel,
    required this.leftSub, required this.rightSub, required this.isLeft,
    required this.leftColor, required this.rightColor,
    required this.onLeft, required this.onRight});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9);
    final bd = isDark ? AppTheme.divider : AppTheme.lightDivider;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: bd)),
      child: Row(children: [
        _tab(context, leftLabel,  leftSub,  isLeft,  leftColor,  onLeft),
        _tab(context, rightLabel, rightSub, !isLeft, rightColor, onRight),
      ]),
    );
  }

  Widget _tab(BuildContext ctx, String label, String sub, bool sel, Color col, VoidCallback onTap) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final unselTs = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final unselTm = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;
    return Expanded(child: GestureDetector(onTap: onTap,
        child: AnimatedContainer(duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
            decoration: BoxDecoration(
                color: sel ? col.withValues(alpha: .15) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: sel ? Border.all(color: col.withValues(alpha: .4)) : null),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700,
                  fontSize: 13, color: sel ? col : unselTs)),
              Text(sub, style: GoogleFonts.plusJakartaSans(
                  fontSize: 11, color: unselTm)),
            ]))));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Assignment Tile
// ─────────────────────────────────────────────────────────────────────────────
class _AssignmentTile extends StatelessWidget {
  final int index;
  final Assignment assignment;
  final List<TimeSlot> timeSlots;
  final List<Room> rooms;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  const _AssignmentTile({required this.index, required this.assignment,
    required this.timeSlots, required this.rooms,
    required this.onDelete, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final col = assignment.startSlot <= 3 ? AppTheme.accentCyan : AppTheme.accentViolet;
    final ts  = timeSlots.where((t) => t.id == assignment.timeSlotId)
        .map((t) => t.label).firstOrNull ?? assignment.timeSlotId;
    final rm  = assignment.hasRoom
        ? rooms.where((r) => r.id == assignment.roomId).map((r) => r.name).firstOrNull
        : null;
    final txtPri = isDark ? AppTheme.textPrimary : AppTheme.lightText;
    final txtSec = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final txtMut = isDark ? AppTheme.textMuted : AppTheme.lightTextMut;

    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: isDark ? AppTheme.solidCard(radius: 14) : AppTheme.solidCardLight(radius: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 28, height: 28,
                decoration: BoxDecoration(color: col.withValues(alpha: .15), shape: BoxShape.circle,
                    border: Border.all(color: col.withValues(alpha: .3))),
                child: Center(child: Text('$index', style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, fontSize: 11, color: col)))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(assignment.course.name, style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, color: txtPri, fontSize: 14)),
              Text('${assignment.teacher.name}  -  ${assignment.classModel.shortCode}',
                  style: GoogleFonts.plusJakartaSans(color: txtSec, fontSize: 12)),
            ])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: col.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: col.withValues(alpha: .3))),
                child: Text(
                    assignment.course.code.length > 7
                        ? assignment.course.code.substring(0,7) : assignment.course.code,
                    style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800,
                        color: col, fontSize: 10))),
            const SizedBox(width: 4),
            IconButton(
                icon: Icon(Icons.edit_outlined, color: AppTheme.accentCyan, size: 18),
                onPressed: onEdit,
                splashRadius: 18,
                tooltip: 'Edit assignment'),
            IconButton(icon: Icon(Icons.delete_outline_rounded, color: txtMut, size: 18),
                onPressed: onDelete, splashRadius: 18, tooltip: 'Delete'),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Chip(assignment.daysLabel, col, Icons.calendar_today_rounded),
            _Chip(ts, AppTheme.accentViolet, Icons.schedule_rounded),
            if (rm != null) _Chip('Rm $rm', AppTheme.accentAmber, Icons.meeting_room_rounded),
            if (assignment.autoAssigned) _Chip('Auto', AppTheme.accentCyan, Icons.auto_awesome_rounded),
          ]),
        ]));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared small widgets
// ─────────────────────────────────────────────────────────────────────────────
class _Chip extends StatelessWidget {
  final String text; final Color color; final IconData icon;
  const _Chip(this.text, this.color, this.icon);
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: .3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color), const SizedBox(width: 5),
        Text(text, style: GoogleFonts.plusJakartaSans(
            fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      ]));
}

class _InfoBox extends StatelessWidget {
  final IconData icon; final Color color; final String text;
  const _InfoBox({required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .25))),
      child: Row(children: [
        Icon(icon, color: color, size: 17), const SizedBox(width: 10),
        Expanded(child: Text(text, style: GoogleFonts.plusJakartaSans(
            color: color, fontWeight: FontWeight.w600, fontSize: 13))),
      ]));
}

// Searchable dropdown: typing in the field filters the entries in a compact,
// field-width popup — so long teacher/course/class lists don't need scrolling
// to find one, and what you type stays visible while you type it.
class _Drop<T extends Object> extends StatelessWidget {
  final String label; final IconData icon; final T? value;
  final Color color; final List<T> items; final String Function(T) itemLabel;
  final ValueChanged<T?> onChanged;
  // When true, shows a clear (×) button once a value is picked, for optional
  // fields (e.g. Room) where the user needs a way back to "none".
  final bool allowClear;
  const _Drop({super.key, required this.label, required this.icon, required this.value,
    required this.color, required this.items, required this.itemLabel, required this.onChanged,
    this.allowClear = false});

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final fillCol = isDark ? AppTheme.bgMid         : const Color(0xFFF8FAFC);
    final bdCol   = isDark ? AppTheme.divider       : AppTheme.lightDivider;
    final txtCol  = isDark ? AppTheme.textPrimary   : AppTheme.lightText;
    final lblCol  = isDark ? AppTheme.textMuted     : AppTheme.lightTextMut;
    final dropBg  = isDark ? AppTheme.bgCard        : Colors.white;

    return LayoutBuilder(builder: (context, constraints) {
      final fieldWidth = constraints.maxWidth;
      return Autocomplete<T>(
        initialValue: TextEditingValue(text: value != null ? itemLabel(value as T) : ''),
        displayStringForOption: itemLabel,
        optionsBuilder: (v) {
          if (v.text.isEmpty) return items;
          final q = v.text.toLowerCase();
          return items.where((i) => itemLabel(i).toLowerCase().contains(q));
        },
        onSelected: onChanged,
        fieldViewBuilder: (context, ctrl, focusNode, onSubmitted) => TextField(
          controller: ctrl, focusNode: focusNode,
          style: GoogleFonts.plusJakartaSans(fontSize: 14, color: txtCol),
          decoration: InputDecoration(
              labelText: label,
              labelStyle: GoogleFonts.plusJakartaSans(color: lblCol, fontSize: 12),
              prefixIcon: Icon(icon, color: lblCol, size: 18),
              suffixIcon: allowClear
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: lblCol, size: 16),
                        onPressed: () { ctrl.clear(); onChanged(null); },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        splashRadius: 14,
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.search_rounded, color: lblCol, size: 18),
                      const SizedBox(width: 12),
                    ])
                  : Icon(Icons.search_rounded, color: lblCol, size: 18),
              filled: true, fillColor: fillCol,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: bdCol)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: bdCol)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: color, width: 1.5)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16)),
        ),
        optionsViewBuilder: (context, onSelected, options) {
          final list = options.toList();
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4, borderRadius: BorderRadius.circular(14), color: dropBg,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 260, maxWidth: fieldWidth),
                child: list.isEmpty
                    ? Padding(padding: const EdgeInsets.all(16),
                        child: Text('No matches', style: GoogleFonts.plusJakartaSans(
                            color: lblCol, fontSize: 13)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        shrinkWrap: true,
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final opt = list[i];
                          return InkWell(
                            onTap: () => onSelected(opt),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Text(itemLabel(opt), style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14, color: txtCol)),
                            ),
                          );
                        },
                      ),
              ),
            ),
          );
        },
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GA Backend Panel
// ─────────────────────────────────────────────────────────────────────────────
class _GaPanel extends StatelessWidget {
  final DataEntryViewModel dataVm;
  final BackendViewModel   vm;
  final VoidCallback?      onNavigateToSchedule;
  const _GaPanel({required this.dataVm, required this.vm, this.onNavigateToSchedule});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? AppTheme.bgCard        : Colors.white;
    final bdCol  = isDark ? AppTheme.divider        : AppTheme.lightDivider;
    final tp     = isDark ? AppTheme.textPrimary    : AppTheme.lightText;
    final ts     = isDark ? AppTheme.textSecondary  : AppTheme.lightTextSec;
    final tm     = isDark ? AppTheme.textMuted      : AppTheme.lightTextMut;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: bdCol),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .2 : .05),
            blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Header bar ───────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withValues(alpha: .3))),
              child: const Icon(Icons.psychology_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AI Genetic Algorithm Engine',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: Colors.white, fontSize: 14)),
              Text('Runs on-device · ${dataVm.assignments.length + dataVm.electiveGroups.length} assignment(s) ready',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 11, color: Colors.white.withValues(alpha: .75))),
            ])),
            // Server status dot
            _ServerDot(alive: true, status: vm.status),
          ]),
        ),

        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Status / result body ──────────────────────────────────────────
            _buildBody(context, tp, ts, tm, isDark),

            const SizedBox(height: 18),

            // ── Action buttons ────────────────────────────────────────────────
            _buildActions(context, tp, ts),
          ]),
        ),
      ]),
    );
  }

  Widget _buildBody(BuildContext ctx, Color tp, Color ts, Color tm, bool isDark) {
    switch (vm.status) {
      case GaStatus.idle:
        return _idleBody(ts, tm);
      case GaStatus.running:
        return _progressBody(
            'AI is generating your timetable…\nThis may take a few seconds.',
            AppTheme.accentViolet, ts);
      case GaStatus.failed:
        return _failedBody(ts, tm);
      case GaStatus.done:
        return _resultBody(ctx, tp, ts, tm, isDark);
    }
  }

  Widget _idleBody(Color ts, Color tm) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        _FeatureChip('Teacher Clash', AppTheme.accentViolet),
        const SizedBox(width: 8),
        _FeatureChip('Room Clash', AppTheme.accentCyan),
        const SizedBox(width: 8),
        _FeatureChip('Section Clash', AppTheme.accentTeal),
      ]),
      const SizedBox(height: 14),
      Text(
        'Press "Run GA" to automatically generate a clash-free timetable. '
            'The AI runs on your device — no internet required.',
        style: GoogleFonts.plusJakartaSans(fontSize: 12, color: ts, height: 1.6),
      ),
    ],
  );

  Widget _progressBody(String msg, Color col, Color ts) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LinearProgressIndicator(
        backgroundColor: col.withValues(alpha: .12),
        valueColor: AlwaysStoppedAnimation(col),
        minHeight: 4,
        borderRadius: BorderRadius.circular(4),
      ),
      const SizedBox(height: 14),
      Text(msg, style: GoogleFonts.plusJakartaSans(
          fontSize: 12, color: ts, height: 1.6)),
    ],
  );


  Widget _failedBody(Color ts, Color tm) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.accentAmber.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.accentAmber.withValues(alpha: .3)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.error_outline_rounded, color: AppTheme.accentAmber, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(vm.errorMessage ?? 'Unknown error',
          style: GoogleFonts.plusJakartaSans(
              fontSize: 12, color: ts, height: 1.6))),
    ]),
  );

  Widget _resultBody(BuildContext ctx, Color tp, Color ts, Color tm, bool isDark) {
    final r         = vm.lastResult!;
    final bd        = r.breakdown;
    final clashFree = r.totalClashes == 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // ── Status banner ─────────────────────────────────────────────────────
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: clashFree
                ? [const Color(0xFF059669), const Color(0xFF10B981)]
                : [const Color(0xFFD97706), const Color(0xFFF59E0B)],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(clashFree ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
              color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(r.message,
              style: GoogleFonts.plusJakartaSans(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
              maxLines: 3, overflow: TextOverflow.ellipsis)),
        ]),
      ),

      const SizedBox(height: 14),

      // ── Stats row ─────────────────────────────────────────────────────────
      Row(children: [
        _StatBadge('Generations', '${r.generationsRun}', AppTheme.accentCyan),
        const SizedBox(width: 8),
        _StatBadge('Hard Clashes', '${r.totalClashes}',
            clashFree ? AppTheme.accentTeal : AppTheme.error),
      ]),

      const SizedBox(height: 14),

      // ── Clash breakdown ───────────────────────────────────────────────────
      Text('Clash Breakdown', style: GoogleFonts.plusJakartaSans(
          fontWeight: FontWeight.w700, fontSize: 12, color: tp)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _ClashTile('Teacher',  bd['H1_teacher_clash'] ?? 0),
        _ClashTile('Room',     bd['H2_room_clash']    ?? 0),
        _ClashTile('Section',  bd['H3_section_clash'] ?? 0),
        if ((bd['total_soft'] ?? 0) > 0)
          _ClashTile('Soft Pen', bd['total_soft'] ?? 0, color: AppTheme.accentCyan),
      ]),
    ]);
  }

  Widget _buildActions(BuildContext ctx, Color tp, Color ts) {
    final isLocked = ctx.watch<SettingsViewModel>().scheduleLocked;
    final canRun = !vm.isRunning && (dataVm.assignments.isNotEmpty || dataVm.electiveGroups.isNotEmpty) && !isLocked;
    return Row(children: [
      // Selective Lock Button
      GestureDetector(
        onTap: () => showDialog(context: ctx, builder: (_) => SelectiveLockDialog(dataVm: dataVm)),
        child: Container(
          height: 48, width: 48,
          margin: const EdgeInsets.only(right: 10),
          decoration: BoxDecoration(
            color: AppTheme.accentAmber.withValues(alpha: .15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentAmber.withValues(alpha: .4)),
          ),
          child: const Icon(Icons.lock_person_rounded, color: AppTheme.accentAmber, size: 20),
        ),
      ),

      // Run GA button
      Expanded(child: GestureDetector(
        onTap: canRun ? () => _runGA(ctx) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 48,
          decoration: BoxDecoration(
            gradient: canRun
                ? const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)])
                : (isLocked ? null : null),
            color: canRun ? null : (isLocked ? AppTheme.error.withValues(alpha: 0.1) : AppTheme.divider),
            borderRadius: BorderRadius.circular(12),
            boxShadow: canRun ? [BoxShadow(
                color: const Color(0xFF4F46E5).withValues(alpha: .35),
                blurRadius: 12, offset: const Offset(0, 4))] : null,
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (vm.isRunning)
              const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            else
              Icon(isLocked ? Icons.lock_rounded : Icons.play_arrow_rounded, 
                  color: isLocked ? AppTheme.error : Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              isLocked ? 'Schedule Locked'
                  : vm.status == GaStatus.running ? 'Running…'
                  : vm.status == GaStatus.done ? 'Re-run GA'
                  : 'Run GA',
              style: GoogleFonts.plusJakartaSans(
                  color: isLocked ? AppTheme.error : Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ]),
        ),
      )),

      if (vm.status == GaStatus.done || vm.status == GaStatus.failed) ...[
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () => ctx.read<BackendViewModel>().reset(),
          child: Container(
            height: 48, width: 48,
            decoration: BoxDecoration(
              color: AppTheme.divider.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.divider),
            ),
            child: Icon(Icons.refresh_rounded, color: ts, size: 20),
          ),
        ),
      ],
    ]);
  }

  Future<void> _runGA(BuildContext ctx) async {
    final settings = ctx.read<SettingsViewModel>();
    if (settings.scheduleLocked) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.lock_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text('Schedule is locked. Unlock in settings to modify.',
                style: GoogleFonts.plusJakartaSans(color: Colors.white, fontWeight: FontWeight.w600))),
          ]),
          backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating));
      return;
    }
    final allocVm  = ctx.read<AllocatorViewModel>();
    // Build shift allowed-slot map for all Bachelors classes
    final shiftAllowed = <String, Set<String>>{};
    for (final cls in dataVm.classes.where(
        (c) => c.level == EducationLevel.bachelors)) {
      final allowed = dataVm.allowedSlotsForClass(cls.id);
      if (allowed != null && allowed.isNotEmpty) {
        shiftAllowed[cls.id] = allowed;
      }
    }
    await ctx.read<BackendViewModel>().runGA(
      teachers:          dataVm.teachers,
      courses:           dataVm.courses,
      classes:           dataVm.classes,
      rooms:             dataVm.rooms,
      timeSlots:         dataVm.timeSlots,
      assignments:       dataVm.assignments,
      timeSlotLocks:     dataVm.timeSlotLocks,
      combinedRules:     dataVm.combinedRules,
      electiveGroups:    dataVm.electiveGroups,
      allocVm:           allocVm,
      dataVm:            dataVm,
      shiftClassAllowed: shiftAllowed,
      workingDays:       settings.workingDays,
      maxPeriods:        settings.maxPeriods,
      populationSize:    settings.gaPop,
      maxGenerations:    settings.gaGen,
    );
    // Show the rich GA report panel after GA finishes
    if (!ctx.mounted) return;
    final result = ctx.read<BackendViewModel>().lastResult;
    if (result != null) {
      showGaReportPanel(
        ctx,
        result,
        onViewSchedule: onNavigateToSchedule,
      );
    }
  }

}

// ── Small helper widgets for the GA panel ──────────────────────────────────

class _ServerDot extends StatelessWidget {
  final bool alive; final GaStatus status;
  const _ServerDot({required this.alive, required this.status});
  @override
  Widget build(BuildContext context) {
    final running = status == GaStatus.running;
    final col = running              ? AppTheme.accentAmber
        : status == GaStatus.done   ? AppTheme.accentTeal
        : status == GaStatus.failed ? AppTheme.error
        : Colors.white.withValues(alpha: .45);
    final label = running                  ? 'Running'
        : status == GaStatus.done   ? 'Done'
        : status == GaStatus.failed ? 'Failed'
        : 'Ready';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: .25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: col)),
        const SizedBox(width: 6),
        Text(label, style: GoogleFonts.plusJakartaSans(
            fontSize: 10, fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: .85))),
      ]),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final String text; final Color color;
  const _FeatureChip(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: .3))),
    child: Text(text, style: GoogleFonts.plusJakartaSans(
        fontSize: 10, fontWeight: FontWeight.w700, color: color)),
  );
}

class _StatBadge extends StatelessWidget {
  final String label, value; final Color color;
  const _StatBadge(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .3))),
    child: Column(children: [
      Text(value, style: GoogleFonts.plusJakartaSans(
          fontWeight: FontWeight.w900, fontSize: 18, color: color)),
      Text(label, style: GoogleFonts.plusJakartaSans(
          fontSize: 9, fontWeight: FontWeight.w600,
          color: color.withValues(alpha: .8)), textAlign: TextAlign.center),
    ]),
  ));
}

class _ClashTile extends StatelessWidget {
  final String label; final int count; final Color? color;
  const _ClashTile(this.label, this.count, {this.color});
  @override
  Widget build(BuildContext context) {
    final col = color ?? (count == 0 ? AppTheme.accentTeal : AppTheme.error);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
          color: col.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: col.withValues(alpha: .3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(count == 0 ? Icons.check_rounded : Icons.close_rounded,
            size: 12, color: col),
        const SizedBox(width: 6),
        Text('$label: $count', style: GoogleFonts.plusJakartaSans(
            fontSize: 11, fontWeight: FontWeight.w700, color: col)),
      ]),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ELECTIVE GROUPS SECTION  (Inter only)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class _ElectiveGroupsSection extends StatefulWidget {
  final DataEntryViewModel dataVm;
  const _ElectiveGroupsSection({required this.dataVm});
  @override
  State<_ElectiveGroupsSection> createState() => _ElectiveGroupsSectionState();
}


class _ElectiveGroupsSectionState extends State<_ElectiveGroupsSection>
    with AutomaticKeepAliveClientMixin {
  // Keep the in-progress elective form alive when it scrolls off-screen —
  // the parent ListView otherwise unmounts it and wipes the half-built group.
  @override
  bool get wantKeepAlive => true;

  // Form state
  bool _expanded = false;
  String? _selTimeSlotId;
  final Set<String> _selClassIds = {};
  // Each entry row: {courseId, teacherId, roomId, roomLabel}
  final List<Map<String, String?>> _entries = [];
  // When editing, holds the id of the group being replaced
  String? _editingGroupId;

  bool get _canSave =>
      _selTimeSlotId != null &&
      _selClassIds.isNotEmpty &&
      _entries.isNotEmpty &&
      _entries.every((e) => e['courseId'] != null && e['teacherId'] != null);

  String _uid() => DateTime.now().microsecondsSinceEpoch.toString();

  void _addEntry() => setState(() => _entries.add({'courseId': null, 'teacherId': null, 'roomId': null, 'roomLabel': null}));
  void _removeEntry(int i) => setState(() => _entries.removeAt(i));

  /// Load an existing group into the form for editing.
  void _startEdit(ElectiveGroup grp) {
    setState(() {
      _editingGroupId = grp.id;
      _selTimeSlotId  = grp.timeSlotId;
      _selClassIds
        ..clear()
        ..addAll(grp.classIds);
      _entries
        ..clear()
        ..addAll(grp.entries.map((e) => {
          'courseId':  e.courseId,
          'teacherId': e.teacherId,
          'roomId':    e.roomId,
          'roomLabel': e.roomLabel,
        }));
      _expanded = true; // open the form
    });
  }

  void _clearForm() {
    setState(() {
      _editingGroupId = null;
      _selTimeSlotId  = null;
      _selClassIds.clear();
      _entries.clear();
    });
  }

  /// Checks whether the currently selected period already has a locked
  /// (fixed) course or a combined-class course occupying it for any of the
  /// selected/candidate sections. Returns a human-readable message, or null
  /// if the period is free.
  String? _slotConflictMessage(DataEntryViewModel dataVm) {
    if (_selTimeSlotId == null) return null;

    // Before sections are picked, warn against every Intermediate section
    // so the clash is visible as soon as a period is chosen.
    final classIdsToCheck = _selClassIds.isNotEmpty
        ? _selClassIds
        : dataVm.classes
            .where((c) => c.level == EducationLevel.intermediate)
            .map((c) => c.id)
            .toSet();

    // ── Time-slot locks (fixed courses) ─────────────────────────────────
    for (final lock in dataVm.timeSlotLocks) {
      if (lock.timeSlotId != _selTimeSlotId) continue;
      if (lock.classId != null && !classIdsToCheck.contains(lock.classId)) {
        continue;
      }
      final clsLabel = lock.className ??
          (lock.classId != null
              ? dataVm.classes
                  .where((c) => c.id == lock.classId)
                  .firstOrNull
                  ?.shortCode
              : null);
      return 'This period is locked for "${lock.courseCode}"'
          '${clsLabel != null ? ' ($clsLabel)' : ''} — pick another period.';
    }

    // ── Combined-class courses already scheduled in this period ────────
    final combinedCourseIds = dataVm.combinedRules
        .where((r) => r.classIds.length > 1)
        .map((r) => r.courseId)
        .toSet();
    for (final a in dataVm.assignments) {
      if (a.timeSlotId != _selTimeSlotId) continue;
      if (!classIdsToCheck.contains(a.classModel.id)) continue;
      if (!combinedCourseIds.contains(a.course.id)) continue;
      return 'In this period, "${a.course.name}" is already combined for '
          '${a.classModel.shortCode} — choose another period or exclude that section.';
    }

    return null;
  }

  void _save() {
    final dataVm = widget.dataVm;

    // ── Slot conflict check (locked / combined course in this period) ──
    final conflict = _slotConflictMessage(dataVm);
    if (conflict != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(conflict,
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // ── Duplicate course check ──────────────────────────────────────────
    final courseIds = _entries.map((e) => e['courseId']).where((id) => id != null).toList();
    final uniqueCourseIds = courseIds.toSet();
    if (uniqueCourseIds.length < courseIds.length) {
      final dupName = _entries
          .map((e) => e['courseId'])
          .where((id) => id != null)
          .fold<Map<String, int>>({}, (m, id) { m[id!] = (m[id] ?? 0) + 1; return m; })
          .entries
          .where((e) => e.value > 1)
          .map((e) => dataVm.courses.where((c) => c.id == e.key).firstOrNull?.name ?? e.key)
          .join(', ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Duplicate course: $dupName — each subject can only appear once.',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // ── Duplicate room check ────────────────────────────────────────────
    final roomIds = _entries.map((e) => e['roomId']).where((id) => id != null).toList();
    final uniqueRoomIds = roomIds.toSet();
    if (uniqueRoomIds.length < roomIds.length) {
      final dupRoom = _entries
          .map((e) => e['roomId'])
          .where((id) => id != null)
          .fold<Map<String, int>>({}, (m, id) { m[id!] = (m[id] ?? 0) + 1; return m; })
          .entries
          .where((e) => e.value > 1)
          .map((e) => dataVm.rooms.where((r) => r.id == e.key).firstOrNull?.name ?? e.key)
          .join(', ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Duplicate room: $dupRoom — each room can only be assigned once.',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
        backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final courses  = {for (final c in dataVm.courses)  c.id: c};

    final teachers = {for (final t in dataVm.teachers) t.id: t};
    final rooms    = {for (final r in dataVm.rooms)    r.id: r};
    final entries  = _entries.map((e) {
      final c = courses[e['courseId']!]!;
      final t = teachers[e['teacherId']!]!;
      final r = e['roomId'] != null ? rooms[e['roomId']] : null;
      return ElectiveEntry(
        id: _uid(),
        courseId: c.id, courseName: c.name,
        teacherId: t.id, teacherName: t.name,
        roomId: r?.id, roomLabel: e['roomLabel'] ?? r?.name,
      );
    }).toList();

    // ── Cross-check: elective course must not already be a regular assignment ──
    // For every class in this group and every elective entry, check regular assignments.
    for (final classId in _selClassIds) {
      final cls = dataVm.classes.where((c) => c.id == classId).firstOrNull;
      for (final entry in entries) {
        final dupAssignment = dataVm.assignments.where((a) =>
            a.classModel.id == classId &&
            a.course.id == entry.courseId).firstOrNull;
        if (dupAssignment != null) {
          final tsLabel = dataVm.timeSlots
              .where((t) => t.id == dupAssignment.timeSlotId).firstOrNull?.label
              ?? dupAssignment.timeSlotId;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '${entry.courseName} is already assigned to '
                  '${cls?.shortCode ?? classId} as a regular class at $tsLabel. '
                  'Remove that assignment first.',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w600, color: Colors.white)),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.all(16),
              duration: const Duration(seconds: 6)));
          return;
        }
      }
    }

    // Helper to check clock overlap between two time slot IDs
    bool localOverlap(String idA, String idB) {
      if (idA == idB) return true;
      final tA = dataVm.timeSlots.where((t) => t.id == idA).firstOrNull;
      final tB = dataVm.timeSlots.where((t) => t.id == idB).firstOrNull;
      if (tA == null || tB == null) return false;
      int parseMin(String t) {
        final p = t.split(':');
        if (p.length != 2) return 0;
        return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
      }
      final aS = parseMin(tA.startTime), aE = parseMin(tA.endTime);
      final bS = parseMin(tB.startTime), bE = parseMin(tB.endTime);
      return aS < bE && bS < aE;
    }

    // ── Cross-elective clash checks ─────────────────────────────────────────
    // Compare this group's (slot, classes, teachers, rooms) against every
    // other saved elective group that uses the same or clock-overlapping slot.
    final thisTsId = _selTimeSlotId!;
    final thisTs   = dataVm.timeSlots.where((t) => t.id == thisTsId).firstOrNull;
    final otherGroups = dataVm.electiveGroups.where((g) => g.id != _editingGroupId);

    for (final other in otherGroups) {
      final otherTs = dataVm.timeSlots.where((t) => t.id == other.timeSlotId).firstOrNull;
      // Only check groups whose slot clock-overlaps with ours
      if (!localOverlap(thisTsId, other.timeSlotId)) continue;

      // 1) Class clash: same class booked by another elective in this slot
      for (final classId in _selClassIds) {
        if (other.classIds.contains(classId)) {
          final cls = dataVm.classes.where((c) => c.id == classId).firstOrNull;
          final otherSlotLabel = otherTs?.label ?? other.timeSlotId;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Class conflict: ${cls?.shortCode ?? classId} is already in '
              'another elective group at $otherSlotLabel. '
              'A class cannot be in two elective groups at the same time.',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16), duration: const Duration(seconds: 6),
          ));
          return;
        }
      }

      // 2) Teacher clash: same teacher in another elective group at this slot
      for (final entry in _entries) {
        final tId = entry['teacherId'];
        if (tId == null || tId.isEmpty) continue;
        final conflictEntry = other.entries.where((e) => e.teacherId == tId).firstOrNull;
        if (conflictEntry != null) {
          final tName = dataVm.teachers.where((t) => t.id == tId).firstOrNull?.name ?? tId;
          final otherSlotLabel = otherTs?.label ?? other.timeSlotId;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Teacher clash: $tName is already assigned to "${conflictEntry.courseName}" '
              'in another elective group at $otherSlotLabel. '
              'A teacher cannot be in two groups at the same time.',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16), duration: const Duration(seconds: 6),
          ));
          return;
        }
      }

      // 3) Room clash: same room in another elective group at this slot
      for (final entry in _entries) {
        final rId = entry['roomId'];
        if (rId == null || rId.isEmpty) continue;
        final conflictEntry = other.entries.where((e) => e.roomId == rId).firstOrNull;
        if (conflictEntry != null) {
          final rLabel = entry['roomLabel'] ?? rId;
          final otherSlotLabel = otherTs?.label ?? other.timeSlotId;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Room conflict: $rLabel is already booked for "${conflictEntry.courseName}" '
              'in another elective group at $otherSlotLabel. '
              'Each room can only be used by one group at a time.',
              style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
            backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16), duration: const Duration(seconds: 6),
          ));
          return;
        }
      }
    }

    // ── Teacher / room vs regular assignment clash check ────────────────────
    // Any regular assignment — pinned or not — in a clock-overlapping slot
    // that uses one of this group's teachers or rooms blocks the save. The
    // scheduler no longer auto-runs on load, so an unpinned overlap would
    // otherwise land in the matrix as a silent clash.
    for (final entry in _entries) {
      final tId = entry['teacherId'];
      final rId = entry['roomId'];
      final conflictAsgn = dataVm.assignments.where((a) {
        if (!localOverlap(thisTsId, a.timeSlotId)) return false;
        final teacherHit = tId != null && tId.isNotEmpty && a.teacher.id == tId;
        final roomHit = rId != null && rId.isNotEmpty && a.hasRoom && a.roomId == rId;
        return teacherHit || roomHit;
      }).firstOrNull;
      if (conflictAsgn != null) {
        final isTeacherHit = tId != null && conflictAsgn.teacher.id == tId;
        final who = isTeacherHit
            ? 'Teacher ${dataVm.teachers.where((t) => t.id == tId).firstOrNull?.name ?? tId}'
            : 'Room ${entry['roomLabel'] ?? rId}';
        final aSlotLabel = dataVm.timeSlots.where((t) => t.id == conflictAsgn.timeSlotId).firstOrNull?.label ?? conflictAsgn.timeSlotId;
        final tsLabel = thisTs?.label ?? thisTsId;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '${isTeacherHit ? "Teacher clash" : "Room clash"}: $who is already booked for '
            '"${conflictAsgn.course.name}" (${conflictAsgn.classModel.shortCode}) at $aSlotLabel, '
            'which overlaps with this elective slot ($tsLabel). '
            'Move or remove that assignment first.',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
          backgroundColor: AppTheme.error, behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16), duration: const Duration(seconds: 8),
        ));
        return;
      }
    }


    final isEditing = _editingGroupId != null;

    final newGroup = ElectiveGroup(
      id: isEditing ? _editingGroupId! : _uid(),
      timeSlotId: _selTimeSlotId!,
      classIds: _selClassIds.toList(),
      entries: entries,
    );

    final conflictingPins = isEditing
        ? dataVm.updateElectiveGroup(newGroup)
        : dataVm.addElectiveGroup(newGroup);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isEditing ? 'Elective group updated!' : 'Elective group saved!',
          style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, color: Colors.white)),
      backgroundColor: AppTheme.success, behavior: SnackBarBehavior.floating,
    ));
    _clearForm();
    if (conflictingPins.isNotEmpty) {
      _askUnpinElectiveConflicts(dataVm, conflictingPins);
    }
  }

  /// Manual cards clash with the just-saved elective's reserved days — ask
  /// before unpinning anything (pins are never released silently).
  void _askUnpinElectiveConflicts(
      DataEntryViewModel dataVm, List<Assignment> conflicts) {
    showDialog(
        context: context,
        builder: (dCtx) => AlertDialog(
              title: Text('Locked cards clash with this elective',
                  style:
                      GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800)),
              content: SingleChildScrollView(
                child: Text(
                    'These manual allocations sit on the elective\'s reserved days:\n\n'
                    '${conflicts.map((a) => '• ${a.course.name} (${a.teacher.name} → ${a.classModel.shortCode})').join('\n')}\n\n'
                    'Unpin them so Fix Now / Run GA may relocate them? '
                    'Keeping them pinned leaves the clash for you to resolve manually.',
                    style: GoogleFonts.plusJakartaSans(fontSize: 13)),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dCtx),
                    child: const Text('Keep pinned')),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(dCtx);
                      dataVm.unpinAssignments(conflicts.map((a) => a.id));
                    },
                    child: const Text('Unpin')),
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final isDark   = Theme.of(context).brightness == Brightness.dark;
    final cardBg   = isDark ? AppTheme.bgCard : Colors.white;
    final bdCol    = isDark ? AppTheme.divider : AppTheme.lightDivider;
    final tp       = isDark ? AppTheme.textPrimary   : AppTheme.lightText;
    final ts       = isDark ? AppTheme.textSecondary : AppTheme.lightTextSec;
    final tm       = isDark ? AppTheme.textMuted     : AppTheme.lightTextMut;
    final dataVm   = widget.dataVm;
    const amber    = AppTheme.accentAmber;

    // Periods: prefer Intermediate-level slots; fall back to ALL if none tagged
    final interSlots = dataVm.timeSlots
        .where((t) => t.level == EducationLevel.intermediate)
        .toList()..sort((a, b) => a.period.compareTo(b.period));
    final allSlots = interSlots.isNotEmpty
        ? interSlots
        : dataVm.timeSlots.toList()..sort((a, b) => a.period.compareTo(b.period));
    final interClasses = dataVm.classes
        .where((c) => c.level == EducationLevel.intermediate).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    // Fall back to all classes if no intermediate-level classes found
    final sectionList = interClasses.isNotEmpty ? interClasses : dataVm.classes.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    if (allSlots.isEmpty || dataVm.classes.isEmpty) return const SizedBox.shrink();



    return Container(
      decoration: BoxDecoration(
        color: cardBg, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: amber.withValues(alpha: .35)),
        boxShadow: [BoxShadow(
            color: amber.withValues(alpha: isDark ? .06 : .04),
            blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Header (tappable to expand/collapse) ─────────────────────────
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          behavior: HitTestBehavior.opaque,
          child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          decoration: BoxDecoration(
            color: amber.withValues(alpha: .08),
            borderRadius: _expanded
                ? const BorderRadius.vertical(top: Radius.circular(18))
                : BorderRadius.circular(18),
            border: _expanded ? Border(bottom: BorderSide(color: bdCol)) : null,
          ),
          child: Row(children: [
            Container(width: 32, height: 32,
                decoration: BoxDecoration(
                    color: amber.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.call_split_rounded, color: amber, size: 18)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Elective Groups  (Inter only)',
                  style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 15, color: tp)),
              Text(
                _editingGroupId != null
                    ? 'Editing group — make changes and save'
                    : _expanded
                        ? 'Tap to collapse'
                        : dataVm.electiveGroups.isEmpty
                            ? 'Tap to add elective split groups'
                            : '${dataVm.electiveGroups.length} group(s) saved — tap to manage',
                style: GoogleFonts.plusJakartaSans(fontSize: 11,
                    color: _editingGroupId != null ? amber : ts)),
            ])),
            Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: amber, size: 22),
          ]),
        )),

        if (_expanded) Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Editing banner ─────────────────────────────────────────────
            if (_editingGroupId != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.accentAmber.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.accentAmber.withValues(alpha: .4)),
                ),
                child: Row(children: [
                  const Icon(Icons.edit_rounded, size: 15, color: AppTheme.accentAmber),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Editing elective group — modify below and tap Update',
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.accentAmber))),
                  TextButton(
                    onPressed: _clearForm,
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: Text('Cancel', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.error)),
                  ),
                ]),
              ),
            ],

            // ── Step 1: Time slot ──────────────────────────────────────────
            Text('1. Shared Period', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 13, color: amber)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selTimeSlotId,
              decoration: InputDecoration(
                labelText: 'Select Shared Period',
                labelStyle: GoogleFonts.plusJakartaSans(color: ts, fontSize: 13),
                filled: true,
                fillColor: isDark ? AppTheme.bgMid : const Color(0xFFF8FAFC),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: bdCol)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              dropdownColor: isDark ? AppTheme.bgCard : Colors.white,
              style: GoogleFonts.plusJakartaSans(color: tp, fontSize: 13),
              items: allSlots.map((ts2) => DropdownMenuItem(
                value: ts2.id,
                child: Text('Period ${ts2.period}  (${ts2.startTime}–${ts2.endTime})',
                    style: GoogleFonts.plusJakartaSans(fontSize: 13, color: tp)),
              )).toList(),
              onChanged: (v) => setState(() => _selTimeSlotId = v),
            ),

            if (_slotConflictMessage(dataVm) != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.error.withValues(alpha: .4)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.error_outline_rounded, size: 16, color: AppTheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_slotConflictMessage(dataVm)!,
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.error))),
                ]),
              ),
            ],

            const SizedBox(height: 20),

            // ── Step 2: Sections ───────────────────────────────────────────
            Text('2. Participating Sections', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 13, color: amber)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8,
              children: sectionList.map((cls) {
                final sel = _selClassIds.contains(cls.id);
                return FilterChip(
                  label: Text(cls.shortCode.isNotEmpty ? cls.shortCode : cls.name,
                      style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w600,
                          color: sel ? Colors.white : ts)),
                  selected: sel,
                  onSelected: (v) => setState(() => v ? _selClassIds.add(cls.id) : _selClassIds.remove(cls.id)),
                  selectedColor: amber,
                  backgroundColor: isDark ? AppTheme.bgMid : const Color(0xFFF1F5F9),
                  checkmarkColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: sel ? amber : bdCol)),
                );
              }).toList(),
            ),

            const SizedBox(height: 20),

            // ── Step 3: Elective entries ───────────────────────────────────
            Row(children: [
              Text('3. Elective Subjects', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 13, color: amber)),
              const Spacer(),
              TextButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.add_rounded, size: 16, color: amber),
                label: Text('Add Subject', style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w700, color: amber)),
              ),
            ]),

            if (_entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Tap "Add Subject" to add each elective course.',
                    style: GoogleFonts.plusJakartaSans(fontSize: 12, color: tm)),
              ),

            ..._entries.asMap().entries.map((entry) {
              final i = entry.key;
              final e = entry.value;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: .05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: amber.withValues(alpha: .2)),
                ),
                child: Column(children: [
                  Row(children: [
                    Container(width: 22, height: 22,
                        decoration: BoxDecoration(color: amber.withValues(alpha: .15), shape: BoxShape.circle),
                        child: Center(child: Text('${i + 1}', style: GoogleFonts.plusJakartaSans(fontSize: 11, fontWeight: FontWeight.w800, color: amber)))),
                    const SizedBox(width: 8),
                    Text('Subject ${i + 1}', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 12, color: tp)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppTheme.error), onPressed: () => _removeEntry(i), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                  ]),
                  const SizedBox(height: 10),
                  // Course — searchable, same widget as the regular Allocator form
                  _Drop<Course>(
                    key: ValueKey('elec-course-$i-${e['courseId']}'),
                    label: 'Course', icon: Icons.menu_book_outlined,
                    value: dataVm.courses.where((c) => c.id == e['courseId']).firstOrNull,
                    color: amber,
                    items: dataVm.courses.where((c) => c.level == EducationLevel.intermediate).toList(),
                    itemLabel: (c) => c.name,
                    onChanged: (v) => setState(() => _entries[i]['courseId'] = v?.id),
                  ),
                  const SizedBox(height: 8),
                  // Teacher — searchable, same widget as the regular Allocator form
                  _Drop<Teacher>(
                    key: ValueKey('elec-teacher-$i-${e['teacherId']}'),
                    label: 'Teacher', icon: Icons.person_outline_rounded,
                    value: dataVm.teachers.where((t) => t.id == e['teacherId']).firstOrNull,
                    color: amber,
                    items: { for (final t in dataVm.teachers) t.id: t }.values.toList(),
                    itemLabel: (t) => t.name,
                    onChanged: (v) => setState(() => _entries[i]['teacherId'] = v?.id),
                  ),
                  const SizedBox(height: 8),
                  // Room — searchable, with a clear (×) button since it's optional
                  if (dataVm.rooms.isNotEmpty)
                    _Drop<Room>(
                      key: ValueKey('elec-room-$i-${e['roomId']}'),
                      label: 'Room (optional)', icon: Icons.meeting_room_outlined,
                      value: dataVm.rooms.where((r) => r.id == e['roomId']).firstOrNull,
                      color: amber,
                      items: dataVm.rooms,
                      itemLabel: (r) => r.name,
                      allowClear: true,
                      onChanged: (v) => setState(() {
                        _entries[i]['roomId'] = v?.id;
                        _entries[i]['roomLabel'] = v?.name;
                      }),
                    )
                  else
                    TextFormField(
                      initialValue: e['roomLabel'],
                      decoration: InputDecoration(labelText: 'Room No. (optional)', labelStyle: GoogleFonts.plusJakartaSans(color: ts, fontSize: 12),
                          filled: true, fillColor: isDark ? AppTheme.bgMid : const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdCol)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                      style: GoogleFonts.plusJakartaSans(color: tp, fontSize: 12),
                      onChanged: (v) => _entries[i]['roomLabel'] = v.trim().isEmpty ? null : v.trim(),
                    ),

                ]),
              );
            }),

            const SizedBox(height: 16),

            // ── Save / Update button ──────────────────────────────────────
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _canSave ? _save : null,
              icon: Icon(_editingGroupId != null ? Icons.check_circle_rounded : Icons.save_rounded, size: 18),
              label: Text(_editingGroupId != null ? 'Update Elective Group' : 'Save Elective Group',
                  style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: amber,
                foregroundColor: Colors.white,
                disabledBackgroundColor: amber.withValues(alpha: .3),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            )),
          ]),
        ),

        // ── Existing elective groups list (only when expanded) ─────────────
        if (_expanded && dataVm.electiveGroups.isNotEmpty) ...[
          Divider(color: bdCol, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Text('Saved Elective Groups', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 13, color: tp)),
          ),
          ...dataVm.electiveGroups.map((grp) {
            final slot = dataVm.timeSlots.where((t) => t.id == grp.timeSlotId).firstOrNull;
            final sections = grp.classIds.map((id) => dataVm.classes.where((c) => c.id == id).firstOrNull?.shortCode ?? id).join(' + ');
            return Container(
              margin: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: amber.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: amber.withValues(alpha: .25)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.schedule_rounded, size: 14, color: amber),
                  const SizedBox(width: 6),
                  Text(slot != null ? 'Period ${slot.period}  (${slot.startTime}–${slot.endTime})' : grp.timeSlotId,
                      style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 12, color: amber)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('• $sections', style: GoogleFonts.plusJakartaSans(fontSize: 11, color: ts), overflow: TextOverflow.ellipsis)),
                  IconButton(
                    icon: const Icon(Icons.edit_rounded, size: 16, color: AppTheme.accentAmber),
                    onPressed: () => _startEdit(grp),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 2),
                  IconButton(icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppTheme.error),
                      onPressed: () => dataVm.removeElectiveGroup(grp.id), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                ]),
                const SizedBox(height: 6),
                ...grp.entries.map((e) => Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 3),
                  child: Row(children: [
                    const Icon(Icons.circle, size: 5, color: amber),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${e.courseName}  —  ${e.teacherName}',
                        style: GoogleFonts.plusJakartaSans(fontSize: 11, color: tp), overflow: TextOverflow.ellipsis)),
                    if (e.roomLabel != null && e.roomLabel!.isNotEmpty)
                      Text('Rm ${e.roomLabel}', style: GoogleFonts.plusJakartaSans(fontSize: 10, fontWeight: FontWeight.w700, color: amber)),
                  ]),
                )),
              ]),
            );
          }),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Undo / Redo icon button
// ─────────────────────────────────────────────────────────────────────────────