import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart' hide Border, BorderStyle;
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_saver/file_saver.dart';
import '../models/assignment.dart';
import '../models/teacher.dart';
import '../models/course.dart';
import '../models/class_model.dart';
import '../models/room.dart';
import '../models/time_slot.dart';
import '../models/education_level.dart';
import '../models/elective_group.dart';
import '../models/combined_rule.dart';
enum ExportFormat { csv, excel }
enum ExportType { studentWise, teacherWise, roomWise }

class AllocatorViewModel extends ChangeNotifier {
  bool _isGenerating = false;
  String? _lastError;
  bool    _gaOptimised   = false;
  String? _gaMessage;
  int     _gaGenerations = 0;
  int     _gaClashes     = 0;
  // Key = classModel.shortCode (e.g. "BS Chemistry-Semester-I")
  Map<String, List<Assignment>> _scheduleByClass   = {};
  Map<String, List<Assignment>> _scheduleByTeacher = {};
  List<Assignment> _allAssignments = [];

  StreamSubscription? _sub;
  bool _isLoading = true;

  /// Per-user Firestore document — scoped to the logged-in user's UID.
  DocumentReference get _doc {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('data')
        .doc('allocator');
  }

  AllocatorViewModel();

  /// Call this AFTER the user has logged in.
  /// Cancels any existing subscription, clears all in-memory data,
  /// then starts a fresh subscription scoped to the current user's UID.
  Future<void> reloadForUser() async {
    _sub?.cancel();
    _sub = null;
    // Clear all in-memory schedule data so previous user's timetable is
    // never visible to the next user or accidentally written to their path.
    _scheduleByClass   = {};
    _scheduleByTeacher = {};
    _allAssignments    = [];
    _isGenerating   = false;
    _lastError      = null;
    _gaOptimised    = false;
    _gaMessage      = null;
    _gaGenerations  = 0;
    _gaClashes      = 0;
    _isLoading      = true;
    notifyListeners(); // immediately clear the UI
    _loadSchedule();
  }



  bool                          get isGenerating      => _isGenerating;
  String?                       get lastError         => _lastError;
  bool                          get hasSchedule       => _allAssignments.isNotEmpty;
  List<Assignment>              get allAssignments    => _allAssignments;
  Map<String, List<Assignment>> get scheduleByClass   => _scheduleByClass;
  Map<String, List<Assignment>> get scheduleByTeacher => _scheduleByTeacher;
  bool    get gaOptimised   => _gaOptimised;
  String? get gaMessage     => _gaMessage;
  int     get gaGenerations => _gaGenerations;
  int     get gaClashes     => _gaClashes;

  String _roomLabel(String? id, List<Room> rooms) {
    if (id == null) return '?';
    for (final r in rooms) {
      if (r.id == id) return r.name;
    }
    return id;
  }

  // ── Credit-hour violations ────────────────────────────────────────────────
  // Compares total occupied DAYS (slots) per course+class against creditHours.
  // e.g. 1 assignment with Mon-Wed = 3 slots → compared against creditHours=2
  List<String> get creditHourViolations {
    final violations = <String>[];
    final Map<String, List<Assignment>> byKey = {};
    for (final a in _allAssignments) {
      final key = '${a.course.id}__${a.classModel.id}';
      byKey.putIfAbsent(key, () => []).add(a);
    }
    for (final entry in byKey.entries) {
      final assignments = entry.value;
      final course   = assignments.first.course;
      final cls      = assignments.first.classModel;
      final expected = course.creditHours;
      // Count total occupied days across all assignments for this course+class
      final actual   = assignments.fold<int>(0, (acc, a) => acc + a.occupiedSlots.length);
      if (actual != expected) {
        final diff = actual < expected
            ? 'needs ${expected - actual} more slot${expected - actual > 1 ? 's' : ''}'
            : 'has ${actual - expected} extra slot${actual - expected > 1 ? 's' : ''}';
        violations.add(
          '${course.name} → ${cls.name}: $actual/$expected slots ($diff)');
      }
    }
    return violations;
  }

  /// Real-minute feasibility per teacher — the "2 Bach slots == 3 Inter slots"
  /// rule made rigorous. For each teacher: required = Σ (slot duration ×
  /// days-per-week) over their assignments (elective entries included by the
  /// caller passing combinedAssignments). Available = per-day union of all
  /// slot windows × working days. required > available ⇒ physically
  /// impossible to schedule clash-free, no matter which algorithm runs.
  static List<String> teacherOverloads(
      List<Assignment> assignments, List<TimeSlot> timeSlots,
      {int workingDays = 6}) {
    int toMin(String t) {
      final p = t.split(':');
      if (p.length != 2) return -1;
      return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
    }

    // Per-day available minutes = union of all slot intervals (both levels)
    final intervals = <List<int>>[];
    for (final t in timeSlots) {
      final s = toMin(t.startTime), e = toMin(t.endTime);
      if (s >= 0 && e > s) intervals.add([s, e]);
    }
    intervals.sort((x, y) => x[0].compareTo(y[0]));
    int dayMinutes = 0;
    int curS = -1, curE = -1;
    for (final iv in intervals) {
      if (curE < 0) { curS = iv[0]; curE = iv[1]; continue; }
      if (iv[0] <= curE) {
        if (iv[1] > curE) curE = iv[1];
      } else {
        dayMinutes += curE - curS;
        curS = iv[0]; curE = iv[1];
      }
    }
    if (curE > 0) dayMinutes += curE - curS;
    final availableWeekly = dayMinutes * workingDays;

    final slotDur = { for (final t in timeSlots)
        t.id: (toMin(t.endTime) - toMin(t.startTime)).clamp(0, 600) };

    // Count distinct (slot, day) cells per teacher — an elective or combined
    // course is ONE physical session no matter how many classes sit in it,
    // so the per-class records must not each add their own minutes.
    // ponytail: cross-level clock-overlapping cells still count separately;
    // fine for a feasibility warning, dedupe by clock interval if it matters.
    final cells = <String, Set<String>>{};   // teacherId -> {tsId|day}
    final names = <String, String>{};
    for (final a in assignments) {
      if (a.teacher.id.isEmpty) continue;
      final set = cells.putIfAbsent(a.teacher.id, () => {});
      for (final d in a.occupiedSlots) {
        set.add('${a.timeSlotId}|$d');
      }
      names[a.teacher.id] = a.teacher.name;
    }
    final required = <String, int>{};   // teacherId -> minutes
    cells.forEach((tid, set) {
      var m = 0;
      for (final cell in set) {
        m += slotDur[cell.substring(0, cell.lastIndexOf('|'))] ?? 40;
      }
      required[tid] = m;
    });

    final out = <String>[];
    required.forEach((tid, req) {
      if (req > availableWeekly) {
        final overBy = req - availableWeekly;
        out.add('${names[tid]}: needs ${req}min/week but only ${availableWeekly}min '
            'exist (over by ${overBy}min ≈ ${(overBy / 40).ceil()} Inter slots). '
            'Reduce this teacher\'s courses.');
      }
    });
    out.sort();
    return out;
  }

  static const List<String> dayNames = [
    'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'
  ];

  // ── Manual greedy preview ─────────────────────────────────────────────────
  ({int startSlot, int duration})? autoFindSlot({
    required Teacher teacher,
    required List<Assignment> existingAssignments,
    int creditHours = 3, // use course credit hours as target duration
  }) {
    // Build candidate durations: try creditHours first, then nearby values
    final candidates = <int>{
      creditHours,
      if (creditHours > 1) creditHours - 1,
      creditHours + 1,
    }.where((d) => d >= 1 && d <= 6).toList()
      ..sort((a, b) => (a - creditHours).abs().compareTo((b - creditHours).abs()));

    for (final dur in candidates) {
      for (int start = 1; start <= 7 - dur; start++) {
        final daysFree = List.generate(dur, (i) => start + i)
            .every((day) => !existingAssignments.any(
                (a) => a.teacher.id == teacher.id && a.occupiedSlots.contains(day)));
        if (daysFree) return (startSlot: start, duration: dur);
      }
    }
    return null;
  }

  // ── Time-interval helpers ─────────────────────────────────────────────────
  static int _parseMin(String t) {
    final p = t.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  /// Returns true if slot A and slot B overlap in real clock time.
  static bool _slotsOverlap(TimeSlot a, TimeSlot b) {
    final aStart = _parseMin(a.startTime);
    final aEnd   = _parseMin(a.endTime);
    final bStart = _parseMin(b.startTime);
    final bEnd   = _parseMin(b.endTime);
    return aStart < bEnd && bStart < aEnd;
  }

  // ── Clash check for manual mode ───────────────────────────────────────────
  /// [timeSlots] must be all time slots (both levels) so cross-level overlap
  /// can be detected. e.g. Bach P1(09:00-10:00) clashes with Inter P1/P2.
  String? checkClash({
    required Teacher    teacher,
    required int        startSlot,
    required int        duration,
    required String     timeSlotId,
    required String     roomId,
    required ClassModel classModel,
    required List<Assignment>    existingAssignments,
    required List<TimeSlot>      timeSlots,
    List<ElectiveGroup>          electiveGroups = const [],
    String? excludeId,
  }) {
    final newSlot = timeSlots.where((t) => t.id == timeSlotId).firstOrNull;
    final newDays = List.generate(duration, (i) => startSlot + i).toSet();

    // ── Check against regular assignments ─────────────────────────────────
    for (final a in existingAssignments) {
      if (a.id == excludeId) continue;
      final aSlot = timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      final timesOverlap = (a.timeSlotId == timeSlotId) ||
          (newSlot != null && aSlot != null && _slotsOverlap(newSlot, aSlot));
      if (!timesOverlap) continue;
      final shared = a.occupiedSlots.toSet().intersection(newDays);
      if (shared.isEmpty) continue;
      final days = shared.map((s) => dayNames[s - 1]).join(', ');
      if (a.teacher.id == teacher.id) {
        return '${teacher.name} already teaches "${a.course.code}" on $days';
      }
      if (roomId.isNotEmpty && a.roomId == roomId) {
        return 'Room ${a.roomId} is occupied by "${a.course.code}" on $days';
      }
      if (a.classModel.id == classModel.id) {
        return '${classModel.name} already has "${a.course.code}" on $days';
      }
    }

    // ── Check against elective group entries (teacher + room conflicts) ────
    for (final grp in electiveGroups) {
      if (grp.timeSlotId != timeSlotId) continue;
      final grpSlot = timeSlots.where((t) => t.id == grp.timeSlotId).firstOrNull;
      final timesOverlap = (grp.timeSlotId == timeSlotId) ||
          (newSlot != null && grpSlot != null && _slotsOverlap(newSlot, grpSlot));
      if (!timesOverlap) continue;
      for (final entry in grp.entries) {
        if (entry.teacherId == teacher.id) {
          return '${teacher.name} is already assigned to "${entry.courseName}" (Elective Group) at this period';
        }
        if (roomId.isNotEmpty && entry.roomLabel != null && entry.roomLabel == roomId) {
          return 'Room $roomId is already used by "${entry.courseName}" (Elective Group) at this period';
        }
      }
      // Also flag if this class is one of the elective group's sections
      if (grp.classIds.contains(classModel.id)) {
        return '${classModel.name} is already in an Elective Group at this period';
      }
    }

    return null;
  }

  // ── Real-time pre-assign validation ───────────────────────────────────────
  String? previewClash({
    required Teacher    teacher,
    required ClassModel classModel,
    required List<int>  days,
    required String     timeSlotId,
    required String     roomId,
    required List<Assignment> existing,
    required List<TimeSlot>   timeSlots,
  }) {
    final newSlot = timeSlots.where((t) => t.id == timeSlotId).firstOrNull;
    for (final a in existing) {
      final aSlot = timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      final timesOverlap = (a.timeSlotId == timeSlotId) ||
          (newSlot != null && aSlot != null && _slotsOverlap(newSlot, aSlot));
      if (!timesOverlap) continue;
      final shared = a.occupiedSlots.toSet().intersection(days.toSet());
      if (shared.isEmpty) continue;
      final dayStr = shared.map((s) => dayNames[s - 1]).join(', ');
      if (a.teacher.id == teacher.id) {
        return '⚠️ ${teacher.name} already teaches "${a.course.code}" on $dayStr at this period.';
      }
      if (roomId.isNotEmpty && a.roomId == roomId) {
        return '⚠️ This room is occupied by "${a.course.code}" on $dayStr.';
      }
      if (a.classModel.id == classModel.id) {
        return '⚠️ ${classModel.name} already has "${a.course.code}" on $dayStr.';
      }
    }
    return null;
  }

  // ── Validate and store a manually-built assignment list ───────────────────
  bool validateAndApply(List<Assignment> assignments, List<TimeSlot> timeSlots,
      {List<CombinedClassRule> combinedRules = const [],
      List<Room> rooms = const []}) {
    _isGenerating = true;
    _lastError = null;
    notifyListeners();

    final clashes = <String>{};

    for (int i = 0; i < assignments.length; i++) {
      final a = assignments[i];
      final slotA = timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      for (int j = i + 1; j < assignments.length; j++) {
        final b = assignments[j];
        final slotB = timeSlots.where((t) => t.id == b.timeSlotId).firstOrNull;
        bool timesOverlap = a.timeSlotId == b.timeSlotId;
        if (!timesOverlap && slotA != null && slotB != null) {
          timesOverlap = _slotsOverlap(slotA, slotB);
        }
        if (!timesOverlap) continue;
        final shared = a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
        if (shared.isEmpty) continue;
        final days = shared.map((s) => dayNames[s - 1]).join(', ');
        // Exempt combined-rule pairs: same course + both classes in a combine rule
        if (a.course.id == b.course.id) {
          final isCmb = combinedRules.any((r) =>
              r.courseId == a.course.id &&
              r.classIds.contains(a.classModel.id) &&
              r.classIds.contains(b.classModel.id));
          if (isCmb) continue;
        }
        if (a.teacher.id == b.teacher.id) {
          clashes.add('Teacher clash: ${a.teacher.name} — "${a.course.name}" & "${b.course.name}" overlap on $days');
        }
        if (a.hasRoom &&
            b.hasRoom &&
            a.roomId == b.roomId &&
            rooms.any((r) => r.id == a.roomId)) {
          clashes.add('Room clash: Room ${_roomLabel(a.roomId, rooms)} — "${a.course.name}" & "${b.course.name}" overlap on $days');
        }
        if (a.classModel.id == b.classModel.id) {
          clashes.add('Class clash: ${a.classModel.name} — "${a.course.name}" & "${b.course.name}" overlap on $days');
        }
      }
    }

    _isGenerating = false;

    if (clashes.isNotEmpty) {
      _lastError = clashes.join('\n');
      notifyListeners();
      return false;
    }

    _applySchedule(assignments);
    notifyListeners();
    return true;
  }

  // ── Cascade-delete helpers (called when entities are deleted from Data tab) ──

  void purgeByTeacherId(String teacherId) {
    if (_allAssignments.isEmpty) return;
    _applySchedule(_allAssignments.where((a) => a.teacher.id != teacherId).toList());
    _saveSchedule();
    notifyListeners();
  }

  void purgeByCourseId(String courseId) {
    if (_allAssignments.isEmpty) return;
    _applySchedule(_allAssignments.where((a) => a.course.id != courseId).toList());
    _saveSchedule();
    notifyListeners();
  }

  void purgeByClassId(String classId) {
    if (_allAssignments.isEmpty) return;
    _applySchedule(_allAssignments.where((a) => a.classModel.id != classId).toList());
    _saveSchedule();
    notifyListeners();
  }

  void purgeByClassIds(Set<String> classIds) {
    if (_allAssignments.isEmpty || classIds.isEmpty) return;
    _applySchedule(_allAssignments.where((a) => !classIds.contains(a.classModel.id)).toList());
    _saveSchedule();
    notifyListeners();
  }

  void clearSchedule() {
    _scheduleByClass   = {};
    _scheduleByTeacher = {};
    _allAssignments    = [];
    _lastError         = null;
    _gaOptimised       = false;
    _gaMessage         = null;
    _gaGenerations     = 0;
    _gaClashes         = 0;
    
    _doc.delete();
    notifyListeners();
  }

  /// Apply a GA-optimised assignment list directly from the backend result.
  /// [gaAssignments] are pre-converted Assignment objects derived from the
  /// chromosome returned by the Python backend.
  void applyGaSchedule(
    List<Assignment> gaAssignments, {
    required String message,
    required int    generations,
    required int    clashes,
  }) {
    _gaOptimised   = true;
    _gaMessage     = message;
    _gaGenerations = generations;
    _gaClashes     = clashes;
    _applySchedule(gaAssignments);
    _saveSchedule();
    notifyListeners();
  }

  void _applySchedule(List<Assignment> assignments) {
    _allAssignments    = assignments;
    _scheduleByClass   = {};
    _scheduleByTeacher = {};
    for (final a in assignments) {
      _scheduleByClass.putIfAbsent(a.classModel.shortCode, () => []).add(a);
      _scheduleByTeacher.putIfAbsent(a.teacher.name, () => []).add(a);
    }
  }

  void _saveSchedule() {
    if (_isLoading) return;
    _doc.set({
      'ga_assignments': jsonEncode(_allAssignments.map((a) => {
        'id': a.id,
        'teacher':    {'id': a.teacher.id, 'name': a.teacher.name, 'department': a.teacher.department},
        'course':     {'id': a.course.id, 'name': a.course.name, 'code': a.course.code, 'creditHours': a.course.creditHours},
        'classModel': {'id': a.classModel.id, 'programId': a.classModel.programId, 'name': a.classModel.name, 'shortCode': a.classModel.shortCode, 'level': a.classModel.level.index},
        'startSlot':    a.startSlot,
        'duration':     a.duration,
        'timeSlotId':   a.timeSlotId,
        'customDays':   a.customDays,
        'roomId':       a.roomId,
        'autoAssigned': a.autoAssigned,
      }).toList()),
      'ga_optimised': _gaOptimised,
      'ga_message': _gaMessage,
      'ga_generations': _gaGenerations,
      'ga_clashes': _gaClashes,
    }, SetOptions(merge: true));
  }

  void _loadSchedule() {
    _sub = _doc.snapshots().listen((snapshot) {
      _isLoading = false;
      if (!snapshot.exists) return;

      final data = snapshot.data() as Map<String, dynamic>;
      try {
        if (data['ga_assignments'] != null) {
          final List decoded = jsonDecode(data['ga_assignments']);
          final loaded = <Assignment>[];
          for (final d in decoded) {
            try {
              final tMap  = d['teacher'];
              final cMap  = d['course'];
              final clMap = d['classModel'];
              loaded.add(Assignment(
                id:           d['id'],
                teacher:      Teacher(id: tMap['id'], name: tMap['name'], department: tMap['department'] ?? ''),
                course:       Course(id: cMap['id'], name: cMap['name'], code: cMap['code'], creditHours: cMap['creditHours'] ?? 3),
                classModel:   ClassModel(
                                id: clMap['id'], programId: clMap['programId'], name: clMap['name'],
                                shortCode: clMap['shortCode'],
                                level: clMap['level'] != null ? EducationLevel.values[clMap['level'] as int] : EducationLevel.intermediate
                              ),
                startSlot:    d['startSlot'],
                duration:     d['duration'],
                timeSlotId:   d['timeSlotId'],
                customDays:   List<int>.from(d['customDays'] ?? []),
                roomId:       d['roomId'],
                autoAssigned: d['autoAssigned'] ?? false,
              ));
            } catch (e) {
              debugPrint('Skipping corrupt ga assignment: $e');
            }
          }
          _allAssignments = loaded;
          _applySchedule(loaded);

          _gaOptimised   = data['ga_optimised'] ?? false;
          _gaMessage     = data['ga_message'];
          _gaGenerations = data['ga_generations'] ?? 0;
          _gaClashes     = data['ga_clashes'] ?? 0;
          notifyListeners();
        }
      } catch (e) {
        debugPrint('Error loading GA schedule: $e');
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ── Backup / restore ──────────────────────────────────────────────────────
  // 'ga_assignments' is a plain nested List (not a jsonEncode'd string) so the
  // backup file on disk is genuine structured JSON, not an escaped-string blob.
  Map<String, dynamic> exportBackupData() => {
    'ga_assignments': _allAssignments.map((a) => {
      'id': a.id,
      'teacher':    {'id': a.teacher.id, 'name': a.teacher.name, 'department': a.teacher.department},
      'course':     {'id': a.course.id, 'name': a.course.name, 'code': a.course.code, 'creditHours': a.course.creditHours},
      'classModel': {'id': a.classModel.id, 'programId': a.classModel.programId, 'name': a.classModel.name, 'shortCode': a.classModel.shortCode, 'level': a.classModel.level.index},
      'startSlot':    a.startSlot,
      'duration':     a.duration,
      'timeSlotId':   a.timeSlotId,
      'customDays':   a.customDays,
      'roomId':       a.roomId,
      'autoAssigned': a.autoAssigned,
    }).toList(),
    'ga_optimised': _gaOptimised,
    'ga_message': _gaMessage,
    'ga_generations': _gaGenerations,
    'ga_clashes': _gaClashes,
  };

  Future<void> importBackup(Map<String, dynamic> data) async {
    final rawGa = data['ga_assignments'];
    if (rawGa == null) return;
    // Backward-compatible: older backup files stored this as a jsonEncode'd
    // string; newer files store the real nested List directly.
    final List decoded = rawGa is String ? jsonDecode(rawGa) : rawGa as List;
    final loaded = <Assignment>[];
    for (final d in decoded) {
      try {
        final tMap  = d['teacher'];
        final cMap  = d['course'];
        final clMap = d['classModel'];
        loaded.add(Assignment(
          id:           d['id'],
          teacher:      Teacher(id: tMap['id'], name: tMap['name'], department: tMap['department'] ?? ''),
          course:       Course(id: cMap['id'], name: cMap['name'], code: cMap['code'], creditHours: cMap['creditHours'] ?? 3),
          classModel:   ClassModel(
                          id: clMap['id'], programId: clMap['programId'], name: clMap['name'],
                          shortCode: clMap['shortCode'],
                          level: clMap['level'] != null ? EducationLevel.values[clMap['level'] as int] : EducationLevel.intermediate
                        ),
          startSlot:    d['startSlot'],
          duration:     d['duration'],
          timeSlotId:   d['timeSlotId'],
          customDays:   List<int>.from(d['customDays'] ?? []),
          roomId:       d['roomId'],
          autoAssigned: d['autoAssigned'] ?? false,
        ));
      } catch (e) {
        debugPrint('Skipping corrupt ga assignment: $e');
      }
    }

    _gaOptimised   = data['ga_optimised'] ?? false;
    _gaMessage     = data['ga_message'];
    _gaGenerations = data['ga_generations'] ?? 0;
    _gaClashes     = data['ga_clashes'] ?? 0;
    _applySchedule(loaded);
    _saveSchedule();
    notifyListeners();
  }

  // =========================================================================
  // UNIFIED EXPORT ENGINE
  //
  // STUDENT-WISE layout:
  //   Col 0 : Program name  (e.g. "BS CHEMISTRY")
  //   Col 1 : Class name    (e.g. "Semester-I")
  //   Col 2+ : Period I, II, III …
  //
  //   Each period cell can hold UP TO 2 courses (days 1-3 + days 4-6):
  //     Line 1: Teacher Name (startDay-endDay)
  //     Line 2: Course Full Name  COURSE-CODE
  //     (blank line between two courses if both exist)
  //
  // TEACHER-WISE layout:
  //   Col 0 : Teacher Name
  //   Col 1 : Department
  //   Col 2+ : Period I, II, III …
  //   Each cell: CourseName\nCourseCode\nClassCode\n(Cr-N)\nCr\nR.room
  // =========================================================================
  static const _typeNames = {
    ExportType.studentWise: 'StudentWise',
    ExportType.teacherWise: 'TeacherWise',
    ExportType.roomWise:    'RoomWise',
  };

  Future<String> exportSchedule({
    required ExportFormat   format,
    required ExportType     type,
    required List<TimeSlot> timeSlots,
    List<Room>              rooms = const [],
    List<ClassModel>        classes = const [],
    List<ElectiveGroup>     electiveGroups = const [],
    int                     workingDays = 6,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final typeName  = _typeNames[type]!;
    final ext       = format == ExportFormat.csv ? 'csv' : 'xlsx';
    final fileName  = 'Timetable_${typeName}_$timestamp';

    final bytes = buildScheduleBytes(
      format: format, type: type, timeSlots: timeSlots,
      rooms: rooms, classes: classes, electiveGroups: electiveGroups,
      workingDays: workingDays,
    );

    final savedPath = await FileSaver.instance.saveFile(
      name: fileName,
      bytes: bytes,
      fileExtension: ext,
      mimeType: format == ExportFormat.csv ? MimeType.csv : MimeType.microsoftExcel,
    );

    return savedPath; // caller shows this in a SnackBar
  }

  /// The actual file-building step, split out from [exportSchedule] so it
  /// can be exercised directly (e.g. round-tripped through the grid
  /// importer) without going through the platform file-save dialog.
  Uint8List buildScheduleBytes({
    required ExportFormat   format,
    required ExportType     type,
    required List<TimeSlot> timeSlots,
    List<Room>              rooms = const [],
    List<ClassModel>        classes = const [],
    List<ElectiveGroup>     electiveGroups = const [],
    int                     workingDays = 6,
  }) {
    if (_allAssignments.isEmpty) throw Exception('No schedule to export.');

    final sortedSlots = List<TimeSlot>.from(timeSlots)
      ..sort((a, b) => a.period.compareTo(b.period));

    const romans = ['I','II','III','IV','V','VI','VII','VIII','IX','X'];
    final typeName = _typeNames[type]!;

    if (format == ExportFormat.csv) {
      final rows    = _buildCsvMatrix(type, sortedSlots, romans, rooms, workingDays);
      final csvData = const ListToCsvConverter().convert(rows);
      return Uint8List.fromList(utf8.encode(csvData));
    }
    final fileBytes = _buildExcel(type, sortedSlots, romans, typeName, rooms, classes, electiveGroups, workingDays);
    if (fileBytes == null) throw Exception('Excel build failed.');
    return Uint8List.fromList(fileBytes);
  }

  // ── Helpers: parse shortCode back into program + class ───────────────────
  /// shortCode is built as "${prog.name}-${class.name}".
  /// We know class.name from the assignment, so strip it from the end.
  ({String program, String className}) _splitShortCode(Assignment a) {
    final sc  = a.classModel.shortCode;
    final cls = a.classModel.name;
    if (sc.endsWith('-$cls') && sc.length > cls.length + 1) {
      return (
        program:   sc.substring(0, sc.length - cls.length - 1),
        className: cls,
      );
    }
    // fallback: whole shortCode as program, empty className
    return (program: sc, className: cls);
  }

  /// Day-range label: "(1-3)", "(4-6)", "(2)", etc.
  String _dayRange(Assignment a) {
    final slots = List<int>.from(a.occupiedSlots)..sort();
    if (slots.isEmpty) return '';
    if (slots.length == 1) return '(${slots.first})';
    return '(${slots.first}-${slots.last})';
  }

  // ── Grid-import-compatible cell text ──────────────────────────────────────
  // TimetableGridImportService's regular-cell parser (_parseCell) reads
  // exactly two lines — teacher, then subject — and pulls a trailing 2-3
  // digit token off either line as the room number; anything past line 2 is
  // ignored, not an error. Matching that shape here (for the one axis the
  // importer actually understands — class rows) means a re-import of a
  // Class-wise export round-trips real assignments back in, not just text.
  //
  // Known gap, inherited from the importer itself: its day-range annotation
  // ("(1-3)") is only recognised for a small fixed set of "combined" subjects
  // (Islamiat, Pakistan Studies, Physical Education, Punjabi, Ethics…), the
  // ones GGC's real sheets actually split that way — an arbitrary partial-
  // week course (e.g. "Math" taught Mon-Wed only) has no representable form
  // in the importer's grammar at all. Rather than fake a format the importer
  // can't read back, a partial-week entry here still exports the full
  // teacher/subject/room on lines 1-2 (so re-import doesn't drop it, just
  // widens it back to the full week) and adds the real day range as a third,
  // human-readable line the parser simply never looks at.

  /// True for the plain numeric room names (`"12"`, `"51"`) the importer's
  /// trailing-token regex can recognise — non-numeric rooms (`"Hall A"`)
  /// still print, just won't be pulled out as a structured room on re-import.
  static bool _isGridRoomToken(String name) => RegExp(r'^\d{2,3}$').hasMatch(name.trim());

  String _roomSuffix(String roomName) =>
      _isGridRoomToken(roomName) ? '  $roomName' : (roomName.isEmpty ? '' : ' ($roomName)');

  /// Class-wise (row = class): "Teacher\nSubject  Room[\n(days)]".
  String _classWiseCellText(Assignment a, String roomName, int workingDays) {
    final lines = [a.teacher.name, '${a.course.name}${_roomSuffix(roomName)}'];
    if (a.occupiedSlots.length < workingDays) lines.add(_dayRange(a));
    return lines.join('\n');
  }

  /// Teacher-wise (row = teacher): "Subject\nClass  Room[\n(days)]".
  String _teacherWiseCellText(Assignment a, String roomName, int workingDays) {
    final lines = [a.course.name, '${a.classModel.shortCode}${_roomSuffix(roomName)}'];
    if (a.occupiedSlots.length < workingDays) lines.add(_dayRange(a));
    return lines.join('\n');
  }

  /// Room-wise (row = room): "Class\nSubject - Teacher[\n(days)]".
  String _roomWiseCellText(Assignment a, int workingDays) {
    final lines = [a.classModel.shortCode, '${a.course.name} - ${a.teacher.name}'];
    if (a.occupiedSlots.length < workingDays) lines.add(_dayRange(a));
    return lines.join('\n');
  }

  /// Groups every room-assigned entry in [_allAssignments] by room name —
  /// the room-wise counterpart of _scheduleByClass/_scheduleByTeacher,
  /// built on demand at export time since it's the only place that needs it.
  Map<String, List<Assignment>> _scheduleByRoom(Map<String, String> roomIdToName) {
    final map = <String, List<Assignment>>{};
    for (final a in _allAssignments) {
      if (!a.hasRoom) continue;
      final name = roomIdToName[a.roomId];
      if (name == null || name.isEmpty) continue;
      map.putIfAbsent(name, () => []).add(a);
    }
    return map;
  }

  // ── CSV matrix ────────────────────────────────────────────────────────────
  List<List<String>> _buildCsvMatrix(
    ExportType     type,
    List<TimeSlot> sortedSlots,
    List<String>   romans,
    List<Room>     rooms,
    int            workingDays,
  ) {
    final rows = <List<String>>[];
    final roomIdToName = { for (final r in rooms) r.id: r.name };

    if (type == ExportType.studentWise) {
      rows.add(['STUDENT / CLASS WISE TIMETABLE']);

      // Header: PROGRAM | CLASS | I | II | …
      final header = <String>['PROGRAM', 'CLASS'];
      for (int i = 0; i < sortedSlots.length; i++) {
        header.add(i < romans.length ? romans[i] : 'P${i + 1}');
      }
      rows.add(header);

      // Time row
      final timeRow = <String>['', 'Daily Time'];
      for (final ts in sortedSlots) {
        timeRow.add('${ts.startTime}-${ts.endTime}');
      }
      rows.add(timeRow);

      // Data rows — sorted by shortCode for stable order
      final validSlotIds = sortedSlots.map((ts) => ts.id).toSet();
      final classKeys = _scheduleByClass.keys.where((k) =>
          _scheduleByClass[k]!.any((a) => validSlotIds.contains(a.timeSlotId))
      ).toList()..sort();

      for (final key in classKeys) {
        final asgnList = _scheduleByClass[key]!;
        final split    = _splitShortCode(asgnList.first);
        final dataRow  = <String>[split.program, split.className];

        for (final ts in sortedSlots) {
          final inSlot = asgnList
              .where((a) => a.timeSlotId == ts.id)
              .toList()
            ..sort((a, b) => (a.occupiedSlots.firstOrNull ?? 0)
                .compareTo(b.occupiedSlots.firstOrNull ?? 0));

          dataRow.add(inSlot.isEmpty ? '' : inSlot
              .map((a) => _classWiseCellText(a, roomIdToName[a.roomId] ?? '', workingDays))
              .join('\n\n'));
        }
        rows.add(dataRow);
      }
    } else if (type == ExportType.teacherWise) {
      rows.add(['DEPARTMENT & TEACHER WISE TIMETABLE']);

      final header = <String>['TEACHER NAME', 'DEPARTMENT'];
      for (int i = 0; i < sortedSlots.length; i++) {
        header.add(i < romans.length ? romans[i] : 'P${i + 1}');
      }
      rows.add(header);

      final timeRow = <String>['Daily Time', ''];
      for (final ts in sortedSlots) {
        timeRow.add('${ts.startTime}-${ts.endTime}');
      }
      rows.add(timeRow);

      final validSlotIds = sortedSlots.map((ts) => ts.id).toSet();
      final teacherKeys = _scheduleByTeacher.keys.where((k) =>
          _scheduleByTeacher[k]!.any((a) => validSlotIds.contains(a.timeSlotId))
      ).toList()..sort();

      for (final tName in teacherKeys) {
        final asgnList = _scheduleByTeacher[tName]!;
        final dept     = asgnList.first.teacher.department;
        final dataRow  = <String>[tName, dept];

        for (final ts in sortedSlots) {
          final inSlot = asgnList.where((a) => a.timeSlotId == ts.id).toList();
          dataRow.add(inSlot.isEmpty ? '' : inSlot
              .map((a) => _teacherWiseCellText(a, roomIdToName[a.roomId] ?? '', workingDays))
              .join('\n---\n'));
        }
        rows.add(dataRow);
      }
    } else {
      // ── Room-Wise ────────────────────────────────────────────────────
      rows.add(['ROOM WISE TIMETABLE']);

      final header = <String>['ROOM'];
      for (int i = 0; i < sortedSlots.length; i++) {
        header.add(i < romans.length ? romans[i] : 'P${i + 1}');
      }
      rows.add(header);

      final timeRow = <String>['Daily Time'];
      for (final ts in sortedSlots) {
        timeRow.add('${ts.startTime}-${ts.endTime}');
      }
      rows.add(timeRow);

      final byRoom = _scheduleByRoom(roomIdToName);
      final validSlotIds = sortedSlots.map((ts) => ts.id).toSet();
      final roomKeys = byRoom.keys.where((k) =>
          byRoom[k]!.any((a) => validSlotIds.contains(a.timeSlotId))
      ).toList()..sort();

      for (final rName in roomKeys) {
        final asgnList = byRoom[rName]!;
        final dataRow  = <String>[rName];

        for (final ts in sortedSlots) {
          final inSlot = asgnList.where((a) => a.timeSlotId == ts.id).toList();
          dataRow.add(inSlot.isEmpty ? '' : inSlot
              .map((a) => _roomWiseCellText(a, workingDays))
              .join('\n---\n'));
        }
        rows.add(dataRow);
      }
    }

    return rows;
  }

  // ── Excel builder ─────────────────────────────────────────────────────────
  List<int>? _buildExcel(
    ExportType          type,
    List<TimeSlot>      allSlots,
    List<String>        romans,
    String              sheetName,
    List<Room>          rooms,
    List<ClassModel>    classes,
    List<ElectiveGroup> electiveGroups,
    int                 workingDays,
  ) {
    final excelDoc = Excel.createExcel();
    final roomIdToName = { for (final r in rooms) r.id: r.name };

    final Border thinBorder = Border(
      borderStyle: BorderStyle.Thin,
      borderColorHex: ExcelColor.fromHexString('#000000'),
    );
    final Border mediumBorder = Border(
      borderStyle: BorderStyle.Medium,
      borderColorHex: ExcelColor.fromHexString('#000000'),
    );

    final CellStyle titleStyle = CellStyle(
      fontFamily: 'Times New Roman',
      bold: true,
      fontSize: 20,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
      textWrapping: TextWrapping.WrapText,
    );

    final CellStyle periodHeaderStyle = CellStyle(
      fontFamily: 'Times New Roman',
      bold: true,
      fontSize: 14,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
      textWrapping: TextWrapping.WrapText,
      leftBorder: thinBorder,
      rightBorder: thinBorder,
      topBorder: mediumBorder,
      bottomBorder: thinBorder,
    );

    final CellStyle labelHeaderStyle = CellStyle(
      fontFamily: 'Times New Roman',
      bold: true,
      fontSize: 14,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
      textWrapping: TextWrapping.WrapText,
      leftBorder: thinBorder,
      rightBorder: thinBorder,
      topBorder: thinBorder,
      bottomBorder: thinBorder,
    );

    final CellStyle dataStyle = CellStyle(
      fontFamily: 'Times New Roman',
      fontSize: 12,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
      textWrapping: TextWrapping.WrapText,
      leftBorder: thinBorder,
      rightBorder: thinBorder,
      topBorder: thinBorder,
      bottomBorder: thinBorder,
    );

    final CellStyle dataStyleLeft = CellStyle(
      fontFamily: 'Times New Roman',
      fontSize: 12,
      horizontalAlign: HorizontalAlign.Left,
      verticalAlign: VerticalAlign.Center,
      textWrapping: TextWrapping.WrapText,
      leftBorder: thinBorder,
      rightBorder: thinBorder,
      topBorder: thinBorder,
      bottomBorder: thinBorder,
    );

    if (type == ExportType.studentWise) {
      for (final level in EducationLevel.values) {
        final levelSlots = allSlots.where((ts) => ts.level == level).toList();
        final classKeys = _scheduleByClass.keys.where((k) {
          return _scheduleByClass[k]!.any((a) => levelSlots.any((ts) => ts.id == a.timeSlotId));
        }).toList()..sort();

        if (classKeys.isEmpty) continue;

        final levelName = level == EducationLevel.intermediate ? 'Intermediate' : 'Bachelors';
        final sheet = excelDoc[levelName];
        final totalCols = 3 + levelSlots.length;

        // Row 0 : Title
        final titleText = '(Affiliated with Punjab University)\nSTUDENT / CLASS WISE TIMETABLE ($levelName)';
        sheet.appendRow(List.generate(totalCols, (i) => TextCellValue(i == 0 ? titleText : ' ')));
        sheet.merge(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
          CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: 0),
        );
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle = titleStyle;
        sheet.setRowHeight(0, 60.0);

        // Row 1 : Headers
        final headerRow = <CellValue>[
          TextCellValue('Class'),
          TextCellValue('Room No.'),
          TextCellValue('Sec'),
        ];
        for (int i = 0; i < levelSlots.length; i++) {
          final ts = levelSlots[i];
          final periodName = i < romans.length ? romans[i] : '${i + 1}';
          headerRow.add(TextCellValue('$periodName\n(${ts.startTime} - ${ts.endTime})'));
        }
        sheet.appendRow(headerRow);
        for (int c = 0; c < headerRow.length; c++) {
          sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 1)).cellStyle =
              c < 3 ? labelHeaderStyle : periodHeaderStyle;
        }
        sheet.setRowHeight(1, 70.0);

        // Group keys by program
        final programToKeys = <String, List<String>>{};
        for (final k in classKeys) {
          final asgn = _scheduleByClass[k]!.first;
          final p = _splitShortCode(asgn);
          programToKeys.putIfAbsent(p.program, () => []).add(k);
        }

        final sortedProgs = programToKeys.keys.toList()..sort();

        for (final prog in sortedProgs) {
          final keys = programToKeys[prog]!;
          final progStartRow = sheet.maxRows;

          for (final key in keys) {
            final rowIdx = sheet.maxRows;
            final asgnList = _scheduleByClass[key]!;
            final firstAsgn = asgnList.first;
            final classModel = firstAsgn.classModel;
            final p = _splitShortCode(firstAsgn);

            // Determine room (use most common or first)
            final roomNames = asgnList
                .map((a) => a.roomId != null ? (roomIdToName[a.roomId] ?? '') : '')
                .where((n) => n.isNotEmpty)
                .toSet();
            final mainRoom = roomNames.isNotEmpty ? roomNames.join(', ') : '';

            final dataRow = <CellValue>[
              TextCellValue(prog),
              TextCellValue(mainRoom),
              TextCellValue(p.className),
            ];

            for (final ts in levelSlots) {
              // Check for elective group first
              final eg = electiveGroups.where((e) => e.timeSlotId == ts.id && e.classIds.contains(classModel.id)).firstOrNull;
              if (eg != null) {
                final egText = eg.entries.map((e) {
                  final rName = e.roomLabel != null ? (roomIdToName[e.roomLabel] ?? e.roomLabel!) : '';
                  return '${e.courseName}: ${e.teacherName} $rName'.trim();
                }).join('\n');
                dataRow.add(TextCellValue(egText));
              } else {
                final inSlot = asgnList.where((a) => a.timeSlotId == ts.id).toList()
                  ..sort((a, b) => (a.occupiedSlots.firstOrNull ?? 0).compareTo(b.occupiedSlots.firstOrNull ?? 0));

                // Genuine "Teacher\nSubject  Room" pairs, blank-line separated
                // when more than one — the exact shape
                // TimetableGridImportService._splitCellEntries/_parseCell
                // reads back, so a re-import round-trips real assignments.
                final cellText = inSlot
                    .map((a) => _classWiseCellText(a, roomIdToName[a.roomId] ?? '', workingDays))
                    .join('\n\n');
                dataRow.add(TextCellValue(cellText));
              }
            }

            sheet.appendRow(dataRow);
            for (int c = 0; c < dataRow.length; c++) {
              final style = (c == 0 || c == 2) ? dataStyleLeft : dataStyle;
              sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIdx)).cellStyle = style;
            }
            sheet.setRowHeight(rowIdx, 90.0);
          }

          if (keys.length > 1) {
            sheet.merge(
              CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: progStartRow),
              CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: progStartRow + keys.length - 1),
            );
          }
        }

        sheet.setColumnWidth(0, 16.0);
        sheet.setColumnWidth(1, 10.0);
        sheet.setColumnWidth(2, 12.0);
        for (int i = 0; i < levelSlots.length; i++) {
          sheet.setColumnWidth(3 + i, 28.0);
        }
      }
      
      if (excelDoc.sheets.containsKey('Intermediate') || excelDoc.sheets.containsKey('Bachelors')) {
        excelDoc.delete('Sheet1');
      }
      
    } else if (type == ExportType.teacherWise) {
      excelDoc.rename('Sheet1', sheetName);
      final sheet = excelDoc[sheetName];
      final totalCols = 2 + allSlots.length;

      // Row 0 : Title
      final titleText = 'DEPARTMENT & TEACHER WISE TIMETABLE';
      sheet.appendRow(List.generate(totalCols, (i) => TextCellValue(i == 0 ? titleText : ' ')));
      sheet.merge(
        CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
        CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: 0),
      );
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle = titleStyle;
      sheet.setRowHeight(0, 60.0);

      // Row 1 : Headers
      final headerRow = <CellValue>[
        TextCellValue('TEACHER NAME'),
        TextCellValue('DEPARTMENT'),
      ];
      for (int i = 0; i < allSlots.length; i++) {
        final periodName = i < romans.length ? romans[i] : 'P${i + 1}';
        headerRow.add(TextCellValue('$periodName\n(${allSlots[i].startTime} - ${allSlots[i].endTime})'));
      }
      sheet.appendRow(headerRow);
      for (int c = 0; c < headerRow.length; c++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 1)).cellStyle =
            c < 2 ? labelHeaderStyle : periodHeaderStyle;
      }
      sheet.setRowHeight(1, 70.0);

      final teacherKeys = _scheduleByTeacher.keys.toList()..sort();
      for (final tName in teacherKeys) {
        final excelRow = sheet.maxRows;
        final asgnList = _scheduleByTeacher[tName]!;
        final dept     = asgnList.first.teacher.department;
        final teacherId = asgnList.first.teacher.id;

        final dataRow = <CellValue>[
          TextCellValue(tName),
          TextCellValue(dept),
        ];

        for (final ts in allSlots) {
          // Check if teacher is in an elective group for this time slot
          final eg = electiveGroups.where((e) => e.timeSlotId == ts.id && e.entries.any((en) => en.teacherId == teacherId)).firstOrNull;
          if (eg != null) {
             final entry = eg.entries.firstWhere((en) => en.teacherId == teacherId);
             final rName = entry.roomLabel != null ? (roomIdToName[entry.roomLabel] ?? entry.roomLabel!) : '';
             final classNameText = classes.where((c) => eg.classIds.contains(c.id)).map((c) => c.shortCode).join(', ');
             dataRow.add(TextCellValue('${entry.courseName}\n$classNameText\n$rName'));
          } else {
             final inSlot = asgnList.where((a) => a.timeSlotId == ts.id).toList();
             dataRow.add(TextCellValue(
               inSlot.isEmpty ? ' ' : inSlot
                   .map((a) => _teacherWiseCellText(a, roomIdToName[a.roomId] ?? '', workingDays))
                   .join('\n---\n')
             ));
          }
        }

        sheet.appendRow(dataRow);
        for (int c = 0; c < dataRow.length; c++) {
          sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: excelRow)).cellStyle = (c == 0 || c == 1) ? dataStyleLeft : dataStyle;
        }
        sheet.setRowHeight(excelRow, 90.0);
      }

      sheet.setColumnWidth(0, 22.0);
      sheet.setColumnWidth(1, 14.0);
      for (int i = 2; i < totalCols; i++) {
        sheet.setColumnWidth(i, 24.0);
      }
    } else {
      // ── Room-Wise ────────────────────────────────────────────────────
      excelDoc.rename('Sheet1', sheetName);
      final sheet = excelDoc[sheetName];
      final totalCols = 1 + allSlots.length;

      final titleText = 'ROOM WISE TIMETABLE';
      sheet.appendRow(List.generate(totalCols, (i) => TextCellValue(i == 0 ? titleText : ' ')));
      sheet.merge(
        CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
        CellIndex.indexByColumnRow(columnIndex: totalCols - 1, rowIndex: 0),
      );
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle = titleStyle;
      sheet.setRowHeight(0, 60.0);

      final headerRow = <CellValue>[TextCellValue('ROOM')];
      for (int i = 0; i < allSlots.length; i++) {
        final periodName = i < romans.length ? romans[i] : 'P${i + 1}';
        headerRow.add(TextCellValue('$periodName\n(${allSlots[i].startTime} - ${allSlots[i].endTime})'));
      }
      sheet.appendRow(headerRow);
      for (int c = 0; c < headerRow.length; c++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 1)).cellStyle =
            c < 1 ? labelHeaderStyle : periodHeaderStyle;
      }
      sheet.setRowHeight(1, 70.0);

      final byRoom = _scheduleByRoom(roomIdToName);
      final roomKeys = byRoom.keys.toList()..sort();
      for (final rName in roomKeys) {
        final excelRow = sheet.maxRows;
        final asgnList = byRoom[rName]!;
        final dataRow = <CellValue>[TextCellValue(rName)];

        for (final ts in allSlots) {
          final inSlot = asgnList.where((a) => a.timeSlotId == ts.id).toList();
          dataRow.add(TextCellValue(
            inSlot.isEmpty ? ' ' : inSlot
                .map((a) => _roomWiseCellText(a, workingDays))
                .join('\n---\n')
          ));
        }

        sheet.appendRow(dataRow);
        for (int c = 0; c < dataRow.length; c++) {
          sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: excelRow)).cellStyle = c == 0 ? dataStyleLeft : dataStyle;
        }
        sheet.setRowHeight(excelRow, 90.0);
      }

      sheet.setColumnWidth(0, 16.0);
      for (int i = 1; i < totalCols; i++) {
        sheet.setColumnWidth(i, 24.0);
      }
    }

    return excelDoc.save();
  }
}