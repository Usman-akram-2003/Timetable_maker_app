import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../viewmodels/data_entry_viewmodel.dart';
import '../../viewmodels/allocator_viewmodel.dart';
import '../../models/education_level.dart';
import '../../models/room.dart';
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

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() { _error = ''; _step = 0; _result = null; });
    try {
      final r = await TimetableGridImportService.pickAndParse(
        onProgress: (p, msg) {
          if (mounted) setState(() { _progress = p; _progressMsg = msg; });
        },
      );
      if (r == null) return; // user cancelled
      if (mounted) setState(() { _result = r; _step = 1; });
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
        final level = result.isIntermediate
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
      }

      _updateProgress(0.15, 'Registering teachers…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 2: Teachers ────────────────────────────────────────────────────────
      final existingTeacherNames = dataVm.teachers
          .map((t) => t.name.toLowerCase().trim())
          .toSet();

      for (final name in result.teacherNames) {
        if (!existingTeacherNames.contains(name.toLowerCase().trim())) {
          dataVm.addTeacher(name);
        }
      }

      _updateProgress(0.30, 'Registering subjects…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 3: Courses ────────────────────────────────────────────────────────
      final level = result.isIntermediate
          ? EducationLevel.intermediate
          : EducationLevel.bachelors;

      final existingCodes = dataVm.courses
          .where((c) => c.level == level)
          .map((c) => c.code.toLowerCase())
          .toSet();

      for (final subject in result.subjectNames) {
        final code = _makeCode(subject);
        if (!existingCodes.contains(code.toLowerCase())) {
          dataVm.addCourse(subject, code, creditHours: 1, level: level);
          existingCodes.add(code.toLowerCase());
        }
      }

      _updateProgress(0.45, 'Creating classes…');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 4: Programs + Classes ─────────────────────────────────────────────
      final existingPrograms = Map<String, String>.fromEntries(
        dataVm.programs.map((p) => MapEntry(p.name.toLowerCase(), p.id)),
      );
      final existingClasses = dataVm.classes
          .map((c) => '${c.programId}__${c.name.toLowerCase()}')
          .toSet();

      for (final cls in result.classes) {
        final progKey = cls.program.toLowerCase();

        // Create program if needed
        if (!existingPrograms.containsKey(progKey)) {
          dataVm.addProgram(cls.program, level);
          // Re-fetch after add
          final newProg = dataVm.programs
              .where((p) => p.name.toLowerCase() == progKey)
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
      final rooms      = dataVm.rooms;
      final timeSlots  = dataVm.timeSlots
          .where((ts) => ts.level == level)
          .toList()
        ..sort((a, b) => a.period.compareTo(b.period));

      for (int i = 0; i < result.assignments.length; i++) {
        final draft = result.assignments[i];

        // Resolve teacher
        final teacher = teachers
            .where((t) => t.name.toLowerCase().trim() == draft.teacherName.toLowerCase().trim())
            .firstOrNull;
        if (teacher == null) continue;

        // Resolve course
        final code = _makeCode(draft.subjectName);
        final course = courses
            .where((c) => c.code.toLowerCase() == code.toLowerCase() && c.level == level)
            .firstOrNull;
        if (course == null) continue;

        // Resolve class
        final classModel = classes
            .where((c) => c.shortCode.toLowerCase().contains(draft.section.toLowerCase()) ||
                          c.name.toLowerCase() == draft.section.toLowerCase())
            .firstOrNull;
        if (classModel == null) continue;

        // Resolve time slot
        if (draft.periodIndex >= timeSlots.length) continue;
        final slot = timeSlots[draft.periodIndex];

        // Resolve room (optional)
        final room = draft.roomNo.isNotEmpty
            ? rooms.where((r) => r.name == draft.roomNo).firstOrNull
            : null;

        // Check for duplicate (same teacher + course + class already assigned)
        final alreadyExists = dataVm.assignments.any((a) =>
            a.teacher.id == teacher.id &&
            a.course.id  == course.id  &&
            a.classModel.id == classModel.id);
        if (alreadyExists) continue;

        dataVm.addAssignment(
          teacher:    teacher,
          course:     course,
          classModel: classModel,
          startSlot:  1,
          duration:   1,
          timeSlotId: slot.id,
          roomId:     room?.id,
          autoAssigned: true,
        );

        if (i % 20 == 0) {
          _updateProgress(0.70 + (0.28 * i / result.assignments.length), 'Building assignments…');
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
                      gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF4F46E5)]),
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
              color: const Color(0xFF6366F1).withValues(alpha: .4),
              width: 2,
              style: BorderStyle.solid,
            ),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.upload_file_rounded, size: 48, color: const Color(0xFF6366F1).withValues(alpha: .7)),
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
        _SummaryCard(label: 'Subjects',    value: '${r.subjectNames.length}', icon: Icons.menu_book_rounded,         color: AppTheme.accentViolet),
        _SummaryCard(label: 'Classes',     value: '${r.classes.length}',      icon: Icons.school_rounded,            color: const Color(0xFFF97316)),
        _SummaryCard(label: 'Rooms',       value: '${r.roomNumbers.length}',  icon: Icons.meeting_room_rounded,      color: AppTheme.accentAmber),
        _SummaryCard(label: 'Periods',     value: '${r.periods.length}',      icon: Icons.schedule_rounded,          color: AppTheme.accentTeal),
        _SummaryCard(label: 'Assignments', value: '${r.assignments.length}',  icon: Icons.assignment_rounded,        color: const Color(0xFF8B5CF6)),
      ]),

      const SizedBox(height: 20),

      // Level badge
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: (r.isIntermediate ? AppTheme.accentTeal : const Color(0xFF8B5CF6)).withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: (r.isIntermediate ? AppTheme.accentTeal : const Color(0xFF8B5CF6)).withValues(alpha: .4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.label_rounded,
              size: 16, color: r.isIntermediate ? AppTheme.accentTeal : const Color(0xFF8B5CF6)),
          const SizedBox(width: 8),
          Text('Level detected: ${r.isIntermediate ? "Intermediate" : "Bachelors"}',
              style: GoogleFonts.plusJakartaSans(fontSize: 13, fontWeight: FontWeight.w700,
                  color: r.isIntermediate ? AppTheme.accentTeal : const Color(0xFF8B5CF6))),
        ]),
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
            backgroundColor: const Color(0xFF6366F1),
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
                  color: const Color(0xFF6366F1),
                  backgroundColor: const Color(0xFF6366F1).withValues(alpha: .15))),
          Text('${(v * 100).round()}%',
              style: GoogleFonts.plusJakartaSans(fontSize: 22, fontWeight: FontWeight.w800,
                  color: const Color(0xFF6366F1))),
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
          backgroundColor: const Color(0xFF6366F1),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => setState(() { _step = 0; _result = null; }),
        child: Text('Import Another File', style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700, color: const Color(0xFF6366F1))),
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
                ? const Color(0xFF6366F1)
                : const Color(0xFF6366F1).withValues(alpha: .2)));
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
            color: done || active ? const Color(0xFF6366F1) : const Color(0xFF6366F1).withValues(alpha: .15),
          ),
          child: Center(child: done
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
              : Text('${idx + 1}',
                  style: GoogleFonts.plusJakartaSans(fontSize: 12, fontWeight: FontWeight.w800,
                      color: active ? Colors.white : const Color(0xFF6366F1).withValues(alpha: .5)))),
        ),
        const SizedBox(height: 4),
        Text(_labels[idx],
            style: GoogleFonts.plusJakartaSans(fontSize: 10, fontWeight: FontWeight.w600,
                color: active ? const Color(0xFF6366F1) : Colors.grey)),
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
      Switch(value: value, onChanged: onChanged, activeThumbColor: const Color(0xFF6366F1)),
    ]);
  }
}
