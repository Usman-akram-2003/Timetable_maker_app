import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/allocator_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../../models/education_level.dart';
import '../../models/time_slot.dart';
import '../../models/room.dart';
import '../../models/elective_group.dart';
import '../../models/teacher.dart';
import '../../models/course.dart';
import '../../services/timetable_grid_import_service.dart';
import '../../app_theme.dart';

class TimetableGridImportScreen extends StatefulWidget {
  /// Called when import is complete so the parent can navigate to the Matrix.
  final VoidCallback? onImportComplete;
  const TimetableGridImportScreen({super.key, this.onImportComplete});

  @override
  State<TimetableGridImportScreen> createState() => _TimetableGridImportScreenState();
}

class _TimetableGridImportScreenState extends State<TimetableGridImportScreen> {
  // ── State ─────────────────────────────────────────────────────────────────
  int    _step        = 0; // 0=pick, 1=preview, 2=applying, 3=done
  double _progress    = 0;
  String _progressMsg = '';
  bool   _mergeMode   = true;  // false → clear existing schedule first
  bool   _createTimeslots = true;

  TimetableGridImportResult? _result;
  String _error = '';
  // Auto-detected level can be wrong (bare department names like
  // "Chemistry" carry no BS/FA-style signal at all) — null means "use
  // _result!.isIntermediate", non-null means the user overrode it.
  bool? _levelOverride;
  bool get _effectiveIsIntermediate => _levelOverride ?? _result!.isIntermediate;

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() { _error = ''; _step = 0; _result = null; });
    try {
      final r = await pickAndParseTimetableFile(
        onProgress: (p, msg) {
          if (mounted) setState(() { _progress = p; _progressMsg = msg; });
        },
      );
      if (r == null) return; // user cancelled
      if (mounted) setState(() { _result = r; _step = 1; _levelOverride = null; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); });
    }
  }

  Future<void> _applyImport() async {
    final result = _result;
    if (result == null) return;

    setState(() { _step = 2; _progress = 0; _progressMsg = 'Starting…'; });

    final dataVm  = context.read<DataEntryViewModel>();
    final allocVm = context.read<AllocatorViewModel>();
    // A grid cell only records WHO teaches WHAT at WHICH period — the source
    // sheet has no day column at all. The college convention (confirmed
    // against real GGC timetables) is that a course occupies its period
    // every working day unless split, so that's the correct default —
    // not the placeholder 1-day/1-credit-hour every import used to get.
    final workingDays = context.read<SettingsViewModel>().workingDays;

    try {
      await Future.delayed(const Duration(milliseconds: 50));

      // ── 0: Optionally clear existing assignments ────────────────────────
      if (!_mergeMode) {
        dataVm.snapshotForUndo('Before Timetable Import');
        // We can't batch-delete via public API — remove one by one
        final ids = dataVm.assignments.map((a) => a.id).toList();
        for (final id in ids) { dataVm.removeAssignment(id); }
      }

      _updateProgress(0.05, 'Creating time slots…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 1: Time Slots ─────────────────────────────────────────────────────
      if (_createTimeslots) {
        final level = _effectiveIsIntermediate
            ? EducationLevel.intermediate
            : EducationLevel.bachelors;

        // Check which start-times already exist so we don't duplicate
        final existingStarts = dataVm.timeSlots
            .where((ts) => ts.level == level)
            .map((ts) => ts.startTime)
            .toSet();

        for (final p in result.periods) {
          if (!existingStarts.contains(p.startTime)) {
            dataVm.addTimeSlot(p.startTime, p.endTime, level);
          }
        }

        // Drop any OTHER slot at this level this file doesn't need, as
        // long as nothing actually uses it — typically the app's generic
        // Clear-Data defaults, once a real file's own periods replace
        // them. Never touches a slot with real assignments/electives on
        // it, so an unrelated day-shift file already imported at the same
        // level is left alone.
        final neededStarts = result.periods.map((p) => p.startTime).toSet();
        final staleSlots = dataVm.timeSlots.where((ts) =>
            ts.level == level &&
            !neededStarts.contains(ts.startTime) &&
            !dataVm.assignments.any((a) => a.timeSlotId == ts.id) &&
            !dataVm.electiveGroups.any((eg) => eg.timeSlotId == ts.id)).toList();
        for (final ts in staleSlots) {
          dataVm.removeTimeSlot(ts.id);
        }

        // addTimeSlot always appends (next period number = last + 1), so a
        // newly-created period that starts earlier in the day than some
        // already-existing slot at this level leaves period numbers out of
        // clock order (e.g. a new 11:30 slot appended after an unrelated
        // unused 13:00 default). Re-sync so P1..Pn always match real time.
        dataVm.renumberTimeSlotsChronologically(level);
      }

      _updateProgress(0.15, 'Registering teachers…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 2: Teachers ────────────────────────────────────────────────────────
      // Re-checks against the live list on every name (not a fixed
      // snapshot) so an abbreviated variant seen later in the same sheet
      // ("M Nawaz" after "Muhammad Nawaz") still resolves to the teacher
      // just created, instead of spawning a second record for the same
      // person — which would hide real clashes between their sections.
      for (final name in result.teacherNames) {
        if (_findTeacher(dataVm.teachers, name) == null) {
          dataVm.addTeacher(name);
        }
      }

      _updateProgress(0.30, 'Registering subjects…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 3: Courses ────────────────────────────────────────────────────────
      final level = _effectiveIsIntermediate
          ? EducationLevel.intermediate
          : EducationLevel.bachelors;

      // A subject parsed from a day-range annotated (combined-slot) cell
      // only meets on those specific days — everything else defaults to
      // the full working week.
      final subjectCreditHours = <String, int>{};
      for (final draft in result.assignments) {
        final d = draft.days;
        if (d == null) continue;
        final code = _makeCode(draft.subjectName).toLowerCase();
        final existing = subjectCreditHours[code];
        if (existing == null || d.length < existing) subjectCreditHours[code] = d.length;
      }

      // Same live-list re-check as teachers above — "Math" resolving to an
      // existing "Mathematics" instead of a second, code-mismatched course.
      for (final subject in result.subjectNames) {
        if (_findCourse(dataVm.courses, subject, level) == null) {
          final code = _makeCode(subject);
          dataVm.addCourse(subject, code,
              creditHours: subjectCreditHours[code.toLowerCase()] ?? workingDays,
              level: level);
        }
      }

      _updateProgress(0.45, 'Creating classes…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 4: Programs + Classes ─────────────────────────────────────────────
      // Keyed by name+level, not name alone — a same-named program at a
      // DIFFERENT level (e.g. an unrelated existing "Chemistry" program)
      // must not be silently reused, or every class/assignment built from
      // it inherits the wrong level.
      final existingPrograms = Map<String, String>.fromEntries(
        dataVm.programs.map((p) => MapEntry('${p.name.toLowerCase()}|${p.level.index}', p.id)),
      );
      final existingClasses = dataVm.classes
          .map((c) => '${c.programId}__${c.name.toLowerCase()}')
          .toSet();

      for (final cls in result.classes) {
        final progKey = '${cls.program.toLowerCase()}|${level.index}';

        // Create program if needed
        if (!existingPrograms.containsKey(progKey)) {
          dataVm.addProgram(cls.program, level);
          // Re-fetch after add
          final newProg = dataVm.programs
              .where((p) => p.name.toLowerCase() == cls.program.toLowerCase() && p.level == level)
              .firstOrNull;
          if (newProg != null) existingPrograms[progKey] = newProg.id;
        }

        final progId = existingPrograms[progKey];
        if (progId == null) continue;

        final clsKey = '${progId}__${cls.section.toLowerCase()}';
        if (!existingClasses.contains(clsKey)) {
          dataVm.addClass(progId, cls.section);
          existingClasses.add(clsKey);
        }
      }

      _updateProgress(0.60, 'Registering rooms…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 5: Rooms ──────────────────────────────────────────────────────────
      final existingRoomNames = dataVm.rooms
          .map((r) => r.name.toLowerCase())
          .toSet();

      for (final roomNo in result.roomNumbers) {
        if (roomNo.isNotEmpty && !existingRoomNames.contains(roomNo.toLowerCase())) {
          dataVm.addRoom(roomNo, RoomType.room);
          existingRoomNames.add(roomNo.toLowerCase());
        }
      }

      _updateProgress(0.70, 'Building assignments…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 6: Assignments ────────────────────────────────────────────────────
      // Re-fetch fresh references now that everything is registered
      final teachers   = dataVm.teachers;
      final courses    = dataVm.courses;
      final classes    = dataVm.classes;
      final programs   = dataVm.programs;
      final rooms      = dataVm.rooms;
      final timeSlots  = dataVm.timeSlots
          .where((ts) => ts.level == level)
          .toList()
        ..sort((a, b) => a.period.compareTo(b.period));
      // periodIndex must resolve by actual clock time, not list position:
      // Step 1 above skips creating a slot whenever one already exists at
      // that start time (e.g. an unused 11:00-12:00 default slot), so the
      // level's slot list can freely interleave old unrelated slots with
      // the newly-created ones in .period-number order. Indexing straight
      // into that list silently paired periodIndex 0/1/2/3 with whichever
      // slots happened to sort first — usually the wrong ones entirely.
      final slotsByStart = { for (final ts in timeSlots) ts.startTime: ts };
      TimeSlot? slotForPeriod(int periodIndex) => periodIndex < result.periods.length
          ? slotsByStart[result.periods[periodIndex].startTime]
          : null;

      for (int i = 0; i < result.assignments.length; i++) {
        final draft = result.assignments[i];

        // Resolve teacher / course (name-fuzzy — see _findTeacher/_findCourse)
        final teacher = _findTeacher(teachers, draft.teacherName);
        if (teacher == null) continue;

        final course = _findCourse(courses, draft.subjectName, level);
        if (course == null) continue;

        // Resolve class — scoped to the draft's own program (and level),
        // not section text alone: two different programs/departments can
        // share a section name (e.g. "Chemistry" and "Mathematics" both
        // have a "V" semester class in the BS-file layout), and matching
        // on section alone let every one of them collide onto whichever
        // class happened to come first in the list.
        final progIds = programs
            .where((p) => p.name.toLowerCase() == draft.programName.toLowerCase() && p.level == level)
            .map((p) => p.id)
            .toSet();
        // draft.section can be empty (a file with no per-row Semester
        // column, e.g. the "BS I"/"BS III" days-column layout before a
        // Semester column exists) — c.shortCode.contains('') is vacuously
        // true for EVERY class in the program, so an empty section must
        // skip that check entirely and rely only on the exact-name match
        // (itself only true for another class that is ALSO section-less),
        // or every classless file's assignments silently attach to
        // whichever OTHER same-program class happens to be first in the
        // list — found via two real files sharing a "Chemistry" program.
        final classModel = classes
            .where((c) => progIds.contains(c.programId) &&
                          ((draft.section.isNotEmpty &&
                            c.shortCode.toLowerCase().contains(draft.section.toLowerCase())) ||
                           c.name.toLowerCase() == draft.section.toLowerCase()))
            .firstOrNull;
        if (classModel == null) continue;

        // Resolve time slot (by clock time — see slotForPeriod above)
        final slot = slotForPeriod(draft.periodIndex);
        if (slot == null) continue;

        // Resolve room (optional)
        final room = draft.roomNo.isNotEmpty
            ? rooms.where((r) => r.name == draft.roomNo).firstOrNull
            : null;

        // draft.days (e.g. [4, 5, 6] for a combined/split-slot entry that
        // meets on the SECOND half of the week) has to reach the actual
        // Assignment as customDays — startSlot/duration alone always
        // render as a contiguous run starting at day 1, so without this
        // every non-day-1-starting entry silently occupied the wrong days.
        final explicitDays = draft.days;

        // Check for duplicate (re-running the same import twice shouldn't
        // pile up repeats) — but teacher+course+class alone isn't enough:
        // the SAME teacher can legitimately teach the SAME course to the
        // SAME class again at a different period/days split (e.g. Munazza
        // Qari's "Islamic Studies" meeting once on day 3 in one period and
        // again on day 4 in another) — that's two real sessions, not a
        // duplicate, so timeSlot and days must match too before skipping.
        bool sameDays(List<int> a, List<int>? b) {
          final bl = b ?? const <int>[];
          return a.length == bl.length && a.toSet().containsAll(bl);
        }
        final alreadyExists = dataVm.assignments.any((a) =>
            a.teacher.id == teacher.id &&
            a.course.id  == course.id  &&
            a.classModel.id == classModel.id &&
            a.timeSlotId == slot.id &&
            sameDays(a.customDays, explicitDays));
        if (alreadyExists) continue;

        dataVm.addAssignment(
          teacher:    teacher,
          course:     course,
          classModel: classModel,
          startSlot:  explicitDays != null && explicitDays.isNotEmpty ? explicitDays.first : 1,
          duration:   explicitDays != null && explicitDays.isNotEmpty
              ? explicitDays.length
              : course.creditHours.clamp(1, workingDays),
          timeSlotId: slot.id,
          customDays: explicitDays ?? const [],
          roomId:     room?.id,
          autoAssigned: true,
        );

        if (i % 20 == 0) {
          _updateProgress(0.70 + (0.15 * i / result.assignments.length), 'Building assignments…');
          await Future.delayed(Duration.zero);
        }
      }

      _updateProgress(0.85, 'Building elective groups…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 7: Elective groups ────────────────────────────────────────────────
      // Each ParsedElectiveDraft is one merged cell — its classNames cover
      // every class row the merge spanned, its entries are the alternate
      // subject/teacher/room options students choose between in that period.
      for (int i = 0; i < result.electives.length; i++) {
        final draft = result.electives[i];

        final slot = slotForPeriod(draft.periodIndex);
        if (slot == null) continue;

        // Scoped by program (+ level, like the assignment loop above) —
        // not section text alone: two different Intermediate files can
        // legitimately produce the same section labels (e.g. both
        // "Arts-I…" and "Arts-II…" recover "A0"/"A1"/"A2" sections from
        // embedded row markers), and matching on section alone let an
        // elective built from one file's rows attach to the OTHER file's
        // same-named class.
        final classIds = <String>{};
        for (final className in draft.classNames) {
          final hasSection = className.contains(' - ');
          final progName = hasSection
              ? className.substring(0, className.lastIndexOf(' - '))
              : className;
          final section = hasSection ? className.split(' - ').last : '';

          final egProgIds = programs
              .where((p) => p.name.toLowerCase() == progName.toLowerCase() && p.level == level)
              .map((p) => p.id)
              .toSet();

          final cls = classes
              .where((c) => egProgIds.contains(c.programId) &&
                            ((section.isNotEmpty &&
                              c.shortCode.toLowerCase().contains(section.toLowerCase())) ||
                             c.name.toLowerCase() == section.toLowerCase()))
              .firstOrNull;
          if (cls != null) classIds.add(cls.id);
        }
        if (classIds.isEmpty) continue;

        final entries = <ElectiveEntry>[];
        for (final opt in draft.entries) {
          final teacher = _findTeacher(teachers, opt.teacherName);
          if (teacher == null) continue;

          final course = _findCourse(courses, opt.subjectName, level);
          if (course == null) continue;

          final room = opt.roomNo.isNotEmpty
              ? rooms.where((r) => r.name == opt.roomNo).firstOrNull
              : null;

          entries.add(ElectiveEntry(
            id: _uid(),
            courseId:  course.id,  courseName:  course.name,
            teacherId: teacher.id, teacherName: teacher.name,
            roomId:    room?.id,   roomLabel:   room?.name,
          ));
        }
        if (entries.isEmpty) continue;

        // Skip an exact duplicate of an already-imported/existing group so
        // re-running the import doesn't pile up repeats.
        final alreadyExists = dataVm.electiveGroups.any((g) =>
            g.timeSlotId == slot.id &&
            g.classIds.toSet().containsAll(classIds) &&
            classIds.containsAll(g.classIds.toSet()) &&
            g.entries.length == entries.length &&
            g.entries.every((e) => entries.any((ne) =>
                ne.courseId == e.courseId && ne.teacherId == e.teacherId)));
        if (alreadyExists) continue;

        dataVm.addElectiveGroup(ElectiveGroup(
          id: _uid(),
          timeSlotId: slot.id,
          classIds: classIds.toList(),
          entries: entries,
        ));

        if (i % 5 == 0) {
          _updateProgress(0.85 + (0.13 * i / result.electives.length), 'Building elective groups…');
          await Future.delayed(Duration.zero);
        }
      }

      _updateProgress(0.99, 'Refreshing schedule…');
      await Future.delayed(const Duration(milliseconds: 30));

      allocVm.validateAndApply(
        dataVm.assignments,
        dataVm.timeSlots,
        combinedRules: dataVm.combinedRules,
        rooms: dataVm.rooms,
      );

      if (mounted) setState(() { _step = 3; _progress = 1.0; _progressMsg = 'Done!'; });

    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _step = 1; });
    }
  }

  void _updateProgress(double p, String msg) {
    if (mounted) setState(() { _progress = p; _progressMsg = msg; });
  }

  String _makeCode(String subject) {
    final words = subject.trim().split(RegExp(r'\s+'));
    if (words.length == 1) return words[0].substring(0, words[0].length.clamp(0, 6)).toUpperCase();
    return words.map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join().substring(0, words.length.clamp(0, 5));
  }

  String _uid() => DateTime.now().microsecondsSinceEpoch.toString();

  // ── Fuzzy identity matching ──────────────────────────────────────────────
  // Source sheets routinely abbreviate names ("Muhammad Nawaz" → "M Nawaz")
  // and subjects ("Mathematics" → "Math") relative to however they're
  // already spelled out in the app's data. Matching on exact string
  // equality alone spawns a duplicate teacher/course per variant instead of
  // resolving to the one that already exists — and a duplicate teacher is
  // worse than cosmetic: the clash checker treats "M Nawaz" and "Muhammad
  // Nawaz" as two different people, so a real double-booking between their
  // sections goes undetected. The actual comparisons live in the service
  // (TimetableGridImportService.teacherNamesMatch/courseNamesMatch) — pure
  // string logic, tested there; these two just apply it against the app's
  // live teacher/course lists.

  Teacher? _findTeacher(List<Teacher> teachers, String name) {
    final target = name.toLowerCase().trim();
    final exact = teachers.where((t) => t.name.toLowerCase().trim() == target).firstOrNull;
    if (exact != null) return exact;
    return teachers
        .where((t) => TimetableGridImportService.teacherNamesMatch(t.name, name))
        .firstOrNull;
  }

  Course? _findCourse(List<Course> courses, String subjectName, EducationLevel level) {
    final code = _makeCode(subjectName).toLowerCase();
    final byCode = courses
        .where((c) => c.level == level && c.code.toLowerCase() == code)
        .firstOrNull;
    if (byCode != null) return byCode;
    return courses
        .where((c) => c.level == level &&
            TimetableGridImportService.courseNamesMatch(c.name, subjectName))
        .firstOrNull;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ────────────────────────────────────────────────
                Row(children: [
                  Container(
                    width: 42, height: 42,
                    decoration: BoxDecoration(
                      gradient: AppTheme.blueGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.upload_file_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Import Timetable from Excel',
                        style: GoogleFonts.plusJakartaSans(fontSize: 18, fontWeight: FontWeight.w800,
                            color: isDark ? Colors.white : const Color(0xFF0F172A))),
                    Text('Reads GGC-format grid files and builds the full schedule',
                        style: GoogleFonts.plusJakartaSans(fontSize: 12,
                            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
                  ]),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white.withValues(alpha: .06) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.close_rounded, size: 18,
                          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec),
                    ),
                  ),
                ]),
                const SizedBox(height: 28),

                // ── Step indicator ────────────────────────────────────────
                _StepIndicator(current: _step),
                const SizedBox(height: 24),

                // ── Content by step ───────────────────────────────────────
                Expanded(child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  child: _buildStep(isDark),
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(bool isDark) {
    switch (_step) {
      case 0: return _buildPickStep(isDark);
      case 1: return _buildPreviewStep(isDark);
      case 2: return _buildApplyingStep(isDark);
      case 3: return _buildDoneStep(isDark);
      default: return const SizedBox.shrink();
    }
  }

  // ── Step 0: Pick file ─────────────────────────────────────────────────────

  Widget _buildPickStep(bool isDark) {
    return Column(key: const ValueKey(0), crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Drop zone
      GestureDetector(
        onTap: _pickFile,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          height: 200,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppTheme.accentBlue.withValues(alpha: .4),
              width: 2,
              style: BorderStyle.solid,
            ),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.upload_file_rounded, size: 48, color: AppTheme.accentBlue.withValues(alpha: .7)),
            const SizedBox(height: 16),
            Text('Click to pick an Excel timetable file',
                style: GoogleFonts.plusJakartaSans(fontSize: 15, fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF0F172A))),
            const SizedBox(height: 6),
            Text('Supports .xlsx files (GGC Sahiwal grid format)',
                style: GoogleFonts.plusJakartaSans(fontSize: 12,
                    color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
          ]),
        ),
      ),

      if (_error.isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.error.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.error.withValues(alpha: .4)),
          ),
          child: Row(children: [
            const Icon(Icons.error_outline_rounded, color: AppTheme.error, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(_error,
                style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppTheme.error))),
          ]),
        ),
      ],

      const SizedBox(height: 24),
      Text('Supported format:', style: GoogleFonts.plusJakartaSans(
          fontWeight: FontWeight.w700, fontSize: 13,
          color: isDark ? Colors.white : const Color(0xFF0F172A))),
      const SizedBox(height: 8),
      _InfoRow(icon: Icons.check_circle_outline, text: 'FSc + I.Com Part I / Part II timetables'),
      _InfoRow(icon: Icons.check_circle_outline, text: 'Arts + ICS / FA timetables'),
      _InfoRow(icon: Icons.check_circle_outline, text: 'BS semester timetables'),
      _InfoRow(icon: Icons.info_outline_rounded, text: 'One file = one level (Intermediate or Bachelor)',
          color: AppTheme.accentAmber),
    ]);
  }

  // ── Step 1: Preview ───────────────────────────────────────────────────────

  Widget _buildPreviewStep(bool isDark) {
    final r = _result!;
    final cardBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);

    return ListView(key: const ValueKey(1), children: [
      // Summary cards
      Wrap(spacing: 12, runSpacing: 12, children: [
        _SummaryCard(label: 'Teachers',    value: '${r.teacherNames.length}', icon: Icons.person_rounded,           color: AppTheme.accentCyan),
        _SummaryCard(label: 'Subjects',    value: '${r.subjectNames.length}', icon: Icons.menu_book_rounded,         color: AppTheme.accentBlue),
        _SummaryCard(label: 'Classes',     value: '${r.classes.length}',      icon: Icons.school_rounded,            color: const Color(0xFFF97316)),
        _SummaryCard(label: 'Rooms',       value: '${r.roomNumbers.length}',  icon: Icons.meeting_room_rounded,      color: AppTheme.accentAmber),
        _SummaryCard(label: 'Periods',     value: '${r.periods.length}',      icon: Icons.schedule_rounded,          color: AppTheme.accentTeal),
        _SummaryCard(label: 'Assignments', value: '${r.assignments.length}',  icon: Icons.assignment_rounded,        color: AppTheme.accentBlue),
      ]),

      const SizedBox(height: 20),

      // Level badge — tap to override if auto-detection got it wrong (bare
      // department names like "Chemistry" carry no BS/FA-style signal).
      GestureDetector(
        onTap: () => setState(() => _levelOverride = !_effectiveIsIntermediate),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: (_effectiveIsIntermediate ? AppTheme.accentTeal : AppTheme.accentBlue).withValues(alpha: .12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: (_effectiveIsIntermediate ? AppTheme.accentTeal : AppTheme.accentBlue).withValues(alpha: .4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.label_rounded,
                size: 16, color: _effectiveIsIntermediate ? AppTheme.accentTeal : AppTheme.accentBlue),
            const SizedBox(width: 8),
            Text(
                '${_levelOverride != null ? "Level" : "Level detected"}: '
                '${_effectiveIsIntermediate ? "Intermediate" : "Bachelors"}',
                style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700,
                    color: _effectiveIsIntermediate ? AppTheme.accentTeal : AppTheme.accentBlue)),
            const SizedBox(width: 6),
            Icon(Icons.edit_rounded, size: 13,
                color: (_effectiveIsIntermediate ? AppTheme.accentTeal : AppTheme.accentBlue).withValues(alpha: .7)),
          ]),
        ),
      ),

      const SizedBox(height: 20),

      // Options
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          _ToggleRow(
            label: 'Auto-create time slots from file',
            subtitle: 'Creates periods like P1 (08:00–08:40)',
            value: _createTimeslots,
            onChanged: (v) => setState(() => _createTimeslots = v),
          ),
          const Divider(height: 24),
          _ToggleRow(
            label: 'Merge with existing schedule',
            subtitle: 'Off = clear all current assignments first',
            value: _mergeMode,
            onChanged: (v) => setState(() => _mergeMode = v),
          ),
        ]),
      ),

      // Warnings
      if (r.warnings.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Warnings (${r.warnings.length})',
            style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700,
                color: AppTheme.accentAmber)),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 140),
          decoration: BoxDecoration(
            color: AppTheme.accentAmber.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.accentAmber.withValues(alpha: .3)),
          ),
          child: ListView.separated(
            padding: const EdgeInsets.all(10),
            itemCount: r.warnings.length,
            separatorBuilder: (_, __) => const Divider(height: 10),
            itemBuilder: (_, i) => Text(r.warnings[i],
                style: GoogleFonts.plusJakartaSans(fontSize: 11,
                    color: isDark ? AppTheme.accentAmber : const Color(0xFF92400E))),
          ),
        ),
      ],

      const SizedBox(height: 24),

      // Action buttons
      Row(children: [
        Expanded(child: OutlinedButton(
          onPressed: () => setState(() { _step = 0; _result = null; }),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text('← Back', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700)),
        )),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: FilledButton(
          onPressed: _applyImport,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accentBlue,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text('Apply Import →', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800)),
        )),
      ]),

      if (_error.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(_error, style: GoogleFonts.plusJakartaSans(fontSize: 12, color: AppTheme.error)),
      ],
      const SizedBox(height: 32),
    ]);
  }

  // ── Step 2: Applying ──────────────────────────────────────────────────────

  Widget _buildApplyingStep(bool isDark) {
    return Column(key: const ValueKey(2), mainAxisAlignment: MainAxisAlignment.center, children: [
      const SizedBox(height: 40),
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: _progress),
        duration: const Duration(milliseconds: 400),
        builder: (_, v, __) => Stack(alignment: Alignment.center, children: [
          SizedBox(width: 120, height: 120,
              child: CircularProgressIndicator(value: v, strokeWidth: 8,
                  color: AppTheme.accentBlue,
                  backgroundColor: AppTheme.accentBlue.withValues(alpha: .15))),
          Text('${(v * 100).round()}%',
              style: GoogleFonts.plusJakartaSans(fontSize: 22, fontWeight: FontWeight.w800,
                  color: AppTheme.accentBlue)),
        ]),
      ),
      const SizedBox(height: 24),
      Text(_progressMsg,
          style: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : const Color(0xFF0F172A))),
    ]);
  }

  // ── Step 3: Done ──────────────────────────────────────────────────────────

  Widget _buildDoneStep(bool isDark) {
    final r = _result!;
    return Column(key: const ValueKey(3), mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: const Color(0xFF10B981).withValues(alpha: .4), blurRadius: 20)],
        ),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 42),
      ),
      const SizedBox(height: 24),
      Text('Import Complete!',
          style: GoogleFonts.plusJakartaSans(fontSize: 22, fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A))),
      const SizedBox(height: 8),
      Text('${r.assignments.length} assignments imported from ${r.fileName}',
          textAlign: TextAlign.center,
          style: GoogleFonts.plusJakartaSans(fontSize: 13,
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
      const SizedBox(height: 32),
      FilledButton.icon(
        onPressed: () {
          widget.onImportComplete?.call();
        },
        icon: const Icon(Icons.grid_view_rounded),
        label: Text('View Schedule Matrix', style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800)),
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.accentBlue,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => setState(() { _step = 0; _result = null; }),
        child: Text('Import Another File', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, color: AppTheme.accentBlue)),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper extension for section name
// ─────────────────────────────────────────────────────────────────────────────
extension on ParsedAssignmentDraft {
  String get section => className.contains(' - ') ? className.split(' - ').last : '';
}

// ─────────────────────────────────────────────────────────────────────────────
// Small reusable widgets
// ─────────────────────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int current;
  const _StepIndicator({required this.current});

  static const _labels = ['Pick File', 'Preview', 'Applying', 'Done'];

  @override
  Widget build(BuildContext context) {
    return Row(children: List.generate(_labels.length * 2 - 1, (i) {
      if (i.isOdd) {
        return Expanded(child: Container(height: 2,
            color: (i ~/ 2) < current
                ? AppTheme.accentBlue
                : AppTheme.accentBlue.withValues(alpha: .2)));
      }
      final idx  = i ~/ 2;
      final done = idx < current;
      final active = idx == current;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 28, height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done || active ? AppTheme.accentBlue : AppTheme.accentBlue.withValues(alpha: .15),
          ),
          child: Center(child: done
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
              : Text('${idx + 1}',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w800,
                      color: active ? Colors.white : AppTheme.accentBlue.withValues(alpha: .5)))),
        ),
        const SizedBox(height: 4),
        Text(_labels[idx],
            style: GoogleFonts.plusJakartaSans(fontSize: 10, fontWeight: FontWeight.w600,
                color: active ? AppTheme.accentBlue : Colors.grey)),
      ]);
    }));
  }
}

class _SummaryCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _SummaryCard({required this.label, required this.value,
      required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 8),
        Text(value, style: GoogleFonts.plusJakartaSans(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
        Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 11,
            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
      ]),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _InfoRow({required this.icon, required this.text, this.color = AppTheme.accentTeal});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: GoogleFonts.plusJakartaSans(fontSize: 13,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.textSecondary : AppTheme.lightTextSec))),
      ]),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.label, required this.subtitle,
      required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : const Color(0xFF0F172A))),
        Text(subtitle, style: GoogleFonts.plusJakartaSans(fontSize: 11,
            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSec)),
      ])),
      Switch(value: value, onChanged: onChanged, activeThumbColor: AppTheme.accentBlue),
    ]);
  }
}
