import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/teacher.dart';
import '../models/course.dart';
import '../models/class_model.dart';
import '../models/room.dart';
import '../models/time_slot.dart';
import '../models/education_level.dart';
import '../models/assignment.dart';
import '../models/time_slot_lock.dart';
import '../models/combined_rule.dart';
import '../models/elective_group.dart';
import '../models/shift_rule.dart';
import '../services/excel_import_service.dart';
import 'settings_viewmodel.dart';

enum TeacherSwapResult { success, notFound, sameTeacher, differentClass, creditMismatch, wouldClash }

/// One concrete, user-approvable fix for a clash produced by
/// [DataEntryViewModel.suggestFixes]. Nothing happens until [apply] is
/// called (an explicit user click); apply re-validates against the current
/// data and returns a result message — stale suggestions refuse safely.
class FixSuggestion {
  final String clash;       // label of the clash this addresses
  final String description; // what will be changed, in plain words
  final String Function() apply;
  FixSuggestion(
      {required this.clash, required this.description, required this.apply});
}

class DataEntryViewModel extends ChangeNotifier {
  final List<String> _departments = [];
  final List<Teacher> _teachers = [];
  final List<Course> _courses = [];
  final List<ProgramGroup> _programs = [];
  final List<ClassModel> _classes = [];
  final List<Room> _rooms = [];
  final List<TimeSlot> _timeSlots = [];
  final List<TimeSlotLock> _timeSlotLocks = [];
  final List<Assignment> _assignments = [];
  final List<CombinedClassRule> _combinedRules = [];
  final List<ElectiveGroup> _electiveGroups = [];
  final List<ShiftRule> _shiftRules = [];

  StreamSubscription? _sub;
  bool _isLoading = true;

  // Set for the duration of fixTeacherClashes(). While true, incoming
  // Firestore snapshots are not applied — fixTeacherClashes yields the UI
  // thread between passes, and a concurrent edit's server-confirmed echo
  // landing mid-run would otherwise clobber _assignments out from under it
  // (the existing hasPendingWrites guard only skips the LOCAL echo of a
  // write, not a real round-trip). Any edit made elsewhere during the run
  // is already reflected in _assignments directly (mutations apply locally
  // before they're persisted), so skipping the snapshot here loses nothing.
  bool _isFixing = false;

  // Ã¢â€â‚¬Ã¢â€â‚¬ Friday Short Day setting (pushed from SettingsViewModel) Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  bool _fridayShortDay = false;
  int _fridayMaxPeriod = 3;

  /// Called by the widget tree whenever SettingsViewModel changes.
  void applySettings(SettingsViewModel s) {
    if (_fridayShortDay != s.fridayShortDay ||
        _fridayMaxPeriod != s.fridayMaxPeriod) {
      _fridayShortDay = s.fridayShortDay;
      _fridayMaxPeriod = s.fridayMaxPeriod;
      notifyListeners(); // re-render matrix with updated blocked slots
    }
  }

  /// Per-user Firestore document — scoped to the logged-in user's UID.
  /// Falls back to 'anonymous' if called before auth is ready (should not happen).
  DocumentReference get _doc {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('data')
        .doc('timetable');
  }

  DataEntryViewModel();

  /// Call this AFTER the user has logged in.
  /// Cancels any existing Firestore subscription, clears all in-memory
  /// data, then starts a fresh subscription scoped to the current user's UID.
  Future<void> reloadForUser() async {
    _sub?.cancel();
    _sub = null;
    // ── Clear all in-memory data so previous user's data is never
    // visible for the next user, and never accidentally saved to the
    // new user's Firestore path.
    _departments.clear();
    _teachers.clear();
    _courses.clear();
    _programs.clear();
    _classes.clear();
    _rooms.clear();
    _timeSlots.clear();
    _timeSlotLocks.clear();
    _assignments.clear();
    _combinedRules.clear();
    _electiveGroups.clear();
    _shiftRules.clear();
    // Reset all state flags
    _hasLoadedData = false;
    _rulesApplied  = false;
    _isLoading     = true;
    notifyListeners(); // immediately clear the UI
    _loadData();
  }


  // Deduplicate by name — teachers imported from multiple depts may appear with different IDs
  List<String> get departments => List.unmodifiable(_departments);
  List<Teacher> get teachers => List.unmodifiable(
      {for (final t in _teachers) t.name.trim().toLowerCase(): t}.values);
  List<Course> get courses => List.unmodifiable(_courses);
  List<ProgramGroup> get programs => List.unmodifiable(_programs);
  List<ClassModel> get classes => List.unmodifiable(_classes);
  List<Room> get rooms => List.unmodifiable(_rooms);
  List<TimeSlot> get timeSlots => List.unmodifiable(_timeSlots);
  List<TimeSlotLock> get timeSlotLocks => List.unmodifiable(_timeSlotLocks);
  List<Assignment> get assignments => List.unmodifiable(_assignments);
  List<CombinedClassRule> get combinedRules =>
      List.unmodifiable(_combinedRules);
  List<ElectiveGroup> get electiveGroups => List.unmodifiable(_electiveGroups);
  List<ShiftRule> get shiftRules => List.unmodifiable(_shiftRules);

  /// Returns the effective shift for a given Bachelors [classId].
  /// If the user has manually set a shift for this class, that is returned.
  /// Otherwise, classes within the same program are auto-distributed:
  ///   first half → morning, second half → evening.
  /// Returns null for Intermediate classes (no shift concept).
  ShiftType? shiftForClass(String classId) {
    // Manual override wins
    final manual = _shiftRules.where((r) => r.classId == classId).firstOrNull;
    if (manual != null) return manual.shift;

    // Auto-assign: find the class and its program siblings
    final cls = _classes.where((c) => c.id == classId).firstOrNull;
    if (cls == null) return null;
    if (cls.level != EducationLevel.bachelors) return null;

    // All Bachelors classes in the same program, sorted by name
    final siblings = _classes
        .where((c) =>
            c.programId == cls.programId && c.level == EducationLevel.bachelors)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    if (siblings.isEmpty) return ShiftType.morning;
    final idx = siblings.indexWhere((c) => c.id == classId);
    if (idx == -1) return ShiftType.morning;

    final half = (siblings.length / 2).ceil();
    return idx < half ? ShiftType.morning : ShiftType.evening;
  }

  /// Returns the allowed Bachelors time slot IDs for [classId] based on its shift.
  /// Morning shift → only P1-P3 (start time < 11:00).
  /// Evening shift  → only P4-P6 (start time >= 11:00).
  /// Returns null for Intermediate (no restriction) or if no slots found.
  Set<String>? allowedSlotsForClass(String classId) {
    final cls = _classes.where((c) => c.id == classId).firstOrNull;
    if (cls == null || cls.level != EducationLevel.bachelors) return null;
    final shift = shiftForClass(classId);
    if (shift == null) return null;
    final boundary = 11 * 60; // 11:00 in minutes
    final allowed = _timeSlots
        .where((ts) => ts.level == EducationLevel.bachelors)
        .where((ts) {
          final parts = ts.startTime.split(':');
          final startMin = (parts.length == 2)
              ? (int.tryParse(parts[0]) ?? 0) * 60 +
                  (int.tryParse(parts[1]) ?? 0)
              : 0;
          return shift == ShiftType.morning
              ? startMin < boundary
              : startMin >= boundary;
        })
        .map((ts) => ts.id)
        .toSet();
    return allowed.isEmpty ? null : allowed;
  }

  /// Same as [allowedSlotsForClass], but also allows the single adjacent
  /// boundary slot when this class's total credit hours exceed its shift's
  /// capacity (slot_count × workingDays) — mirrors the overflow rule used by
  /// the GA allocator (backend_viewmodel.dart) so manual/local relocation
  /// (e.g. "Fix Now") doesn't move a class across shifts, only spills a
  /// single overflow course into the adjacent boundary period when the
  /// class's own shift genuinely has no room left.
  ///   Morning overflow → unlock first evening slot (e.g. P4)
  ///   Evening overflow → unlock last  morning slot (e.g. P3)
  Set<String>? effectiveAllowedSlotsForClass(String classId, int workingDays) {
    final allowed = allowedSlotsForClass(classId);
    if (allowed == null) return null;

    const boundary = 11 * 60; // 11:00 in minutes
    int parseMin(String t) {
      final p = t.split(':');
      if (p.length < 2) return 0;
      return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
    }

    final bachSlots = _timeSlots.where((ts) => ts.level == EducationLevel.bachelors).toList();
    final morningSlots = bachSlots.where((ts) => parseMin(ts.startTime) < boundary).toList()
      ..sort((a, b) => parseMin(a.startTime).compareTo(parseMin(b.startTime)));
    final eveningSlots = bachSlots.where((ts) => parseMin(ts.startTime) >= boundary).toList()
      ..sort((a, b) => parseMin(a.startTime).compareTo(parseMin(b.startTime)));

    final mornIds = morningSlots.map((s) => s.id).toSet();
    final evenIds = eveningSlots.map((s) => s.id).toSet();
    final inMorning = allowed.any(mornIds.contains);
    final inEvening = allowed.any(evenIds.contains);

    final totalCrHrs = _assignments
        .where((a) => a.classModel.id == classId)
        .fold(0, (acc, a) => acc + a.course.creditHours);

    final result = Set<String>.from(allowed);
    if (inMorning && !inEvening) {
      if (totalCrHrs > morningSlots.length * workingDays && eveningSlots.isNotEmpty) {
        result.add(eveningSlots.first.id);
      }
    } else if (inEvening && !inMorning) {
      if (totalCrHrs > eveningSlots.length * workingDays && morningSlots.isNotEmpty) {
        result.add(morningSlots.last.id);
      }
    }
    return result;
  }

  List<Assignment> get combinedAssignments {
    final list = List<Assignment>.from(_assignments);
    for (final eGroup in _electiveGroups) {
      for (final entry in eGroup.entries) {
        final c = _courses.firstWhere((c) => c.id == entry.courseId,
            orElse: () => Course(id: '', code: '?', name: '?', creditHours: 3));
        final t = _teachers.firstWhere((t) => t.id == entry.teacherId,
            orElse: () => Teacher(id: '', name: '?', department: ''));
        final r = entry.roomId != null
            ? _rooms.firstWhere((r) => r.id == entry.roomId,
                orElse: () => Room(id: '', name: '?', type: RoomType.room))
            : null;
        for (final classId in eGroup.classIds) {
          final cls = _classes.firstWhere((cls) => cls.id == classId,
              orElse: () => ClassModel(
                  id: '',
                  programId: '',
                  name: '?',
                  shortCode: '?',
                  level: EducationLevel.intermediate));
          list.add(Assignment(
            id: 'elec_${eGroup.id}_${entry.id}_$classId',
            timeSlotId: eGroup.timeSlotId,
            classModel: cls,
            course: c,
            teacher: t,
            roomId: r?.id,
            startSlot: 1,
            duration: c.creditHours,
          ));
        }
      }
    }
    return list;
  }

  /// Days an elective group actually occupies: the FIRST N days of its
  /// period, N = max credit hours among its entries (matches how
  /// [combinedAssignments] renders elective cards: startSlot 1, duration =
  /// creditHours). The remaining days of that period are free for regular
  /// courses.
  List<int> electiveOccupiedDays(ElectiveGroup eg) {
    int maxCr = 1;
    for (final e in eg.entries) {
      final cr = _courses
              .where((c) => c.id == e.courseId)
              .firstOrNull
              ?.creditHours ??
          3; // same default as combinedAssignments
      if (cr > maxCr) maxCr = cr;
    }
    return List<int>.generate(maxCr, (i) => i + 1);
  }

  // ── Elective Groups CRUD ────────────────────────

  /// Returns the manual cards that conflict with the group's reserved days —
  /// the caller must ask the user before unpinning any of them.
  List<Assignment> addElectiveGroup(ElectiveGroup group) {
    _electiveGroups.add(group);
    notifyListeners();
    _saveData();
    return electiveConflictingPins(group);
  }

  /// Manual (pinned) assignments whose slot+days conflict with the given
  /// elective group (same class or same teacher in a clock-overlapping slot,
  /// on the elective's reserved days). Query only — never mutates.
  List<Assignment> electiveConflictingPins(ElectiveGroup eg) {
    if (eg.timeSlotId.isEmpty) return const [];
    final egSlot = _timeSlots.where((t) => t.id == eg.timeSlotId).firstOrNull;
    if (egSlot == null) return const [];
    final egTeachers =
        eg.entries.map((e) => e.teacherId).where((t) => t.isNotEmpty).toSet();

    final out = <Assignment>[];
    for (final a in _assignments) {
      if (a.autoAssigned) continue; // already free
      final aSlot = _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      if (aSlot == null) continue;
      if (!_slotsOverlap(egSlot, aSlot)) continue; // no clock overlap
      // Leftover days of the elective period don't conflict — keep the pin.
      if (!a.occupiedSlots.any(electiveOccupiedDays(eg).contains)) continue;
      if (eg.classIds.contains(a.classModel.id) ||
          egTeachers.contains(a.teacher.id)) {
        out.add(a);
      }
    }
    return out;
  }

  /// Releases the pin on the given assignments so solvers may relocate them.
  /// Called only after the user explicitly confirms.
  void unpinAssignments(Iterable<String> ids) {
    final idSet = ids.toSet();
    for (int i = 0; i < _assignments.length; i++) {
      if (idSet.contains(_assignments[i].id)) {
        _assignments[i] = _assignments[i].copyWith(autoAssigned: true);
      }
    }
    notifyListeners();
    _saveData();
  }

  void removeElectiveGroup(String id) {
    _electiveGroups.removeWhere((g) => g.id == id);
    notifyListeners();
    _saveData();
  }

  /// Returns the manual cards that conflict with the group's reserved days —
  /// the caller must ask the user before unpinning any of them.
  List<Assignment> updateElectiveGroup(ElectiveGroup updated) {
    final idx = _electiveGroups.indexWhere((g) => g.id == updated.id);
    if (idx == -1) return const [];
    _electiveGroups[idx] = updated;
    notifyListeners();
    _saveData();
    return electiveConflictingPins(updated);
  }

  /// Writes GA-optimised positions back into the main assignment list so the
  /// matrix (which reads dataVm) immediately reflects the new schedule.
  /// GA result IDs look like '`<origId>_ga_<n>`' — we match on the original ID.
  /// Pinned (autoAssigned=false) assignments keep their pin flag; the GA already
  /// respected their locked position, so only day/slot/room fields are synced.
  int applyGaResults(List<Assignment> gaAssignments) {
    int updated = 0;
    for (final ga in gaAssignments) {
      // Extract original assignment ID from the GA id pattern '<origId>_ga_<n>'
      final gaIdx = ga.id.lastIndexOf('_ga_');
      final origId = gaIdx > 0 ? ga.id.substring(0, gaIdx) : ga.id;
      final i = _assignments.indexWhere((a) => a.id == origId);
      if (i == -1) continue;
      final orig = _assignments[i];
      _assignments[i] = orig.copyWith(
        startSlot: ga.startSlot,
        duration: ga.duration,
        timeSlotId: ga.timeSlotId,
        customDays: List<int>.from(ga.customDays),
        // Rooms are manual-only: the scheduler moves days/slots, never rooms.
        // Keep the original pin state: pinned stays pinned, free stays free.
        autoAssigned: orig.autoAssigned,
      );
      updated++;
    }
    if (updated > 0) {
      notifyListeners();
      _saveData();
    }
    return updated;
  }

  /// Replaces a teacher's assignments/elective entries for specific classes.
  /// [replacements] maps teacherId → {classId → newTeacher}, so only that
  /// teacher's assignments
  /// for that specific class are handed off, leaving their other classes
  /// untouched. Elective entries are combined-session by nature (one
  /// teacher/room per entry covers every class in the group), so matching
  /// ANY selected class of the group hands off the whole entry.
  int replaceTeacherForClasses(Map<String, Map<String, Teacher>> replacements) {
    int count = 0;
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      final newT = replacements[a.teacher.id]?[a.classModel.id];
      if (newT != null) {
        _assignments[i] = a.copyWith(teacher: newT);
        count++;
      }
    }
    for (int g = 0; g < _electiveGroups.length; g++) {
      final eg = _electiveGroups[g];
      bool changed = false;
      final newEntries = eg.entries.map((e) {
        final byClass = replacements[e.teacherId];
        if (byClass == null) return e;
        final newT = eg.classIds.map((cid) => byClass[cid]).whereType<Teacher>().firstOrNull;
        if (newT != null) {
          changed = true;
          count++;
          return e.copyWith(teacherId: newT.id, teacherName: newT.name);
        }
        return e;
      }).toList();
      if (changed) _electiveGroups[g] = eg.copyWith(entries: newEntries);
    }
    if (count > 0) {
      notifyListeners();
      _saveData();
    }
    return count;
  }

  /// Swaps the teachers of two regular assignments belonging to the SAME
  /// class, without re-running the allocator — day/period/room/course stay
  /// exactly as they are, only the `teacher` field on each record flips.
  TeacherSwapResult swapAssignmentTeachers(String assignmentIdA, String assignmentIdB) {
    final idxA = _assignments.indexWhere((a) => a.id == assignmentIdA);
    final idxB = _assignments.indexWhere((a) => a.id == assignmentIdB);
    if (idxA == -1 || idxB == -1) return TeacherSwapResult.notFound;
    final a = _assignments[idxA];
    final b = _assignments[idxB];
    if (a.teacher.id == b.teacher.id) return TeacherSwapResult.sameTeacher;
    if (a.classModel.id != b.classModel.id) return TeacherSwapResult.differentClass;
    if (a.course.creditHours != b.course.creditHours) return TeacherSwapResult.creditMismatch;

    // Would handing this slot to the other teacher double-book them
    // somewhere else on their existing schedule?
    bool wouldClash(Assignment moving, Teacher incoming, String excludeId) {
      final movingKeys = moving.occupiedSlots
          .map((s) => '${incoming.id}__${s}__${moving.timeSlotId}')
          .toSet();
      final existingKeys = _assignments
          .where((x) => x.id != excludeId && x.teacher.id == incoming.id)
          .expand((x) => x.teacherKeys)
          .toSet();
      return movingKeys.intersection(existingKeys).isNotEmpty;
    }
    if (wouldClash(a, b.teacher, b.id) || wouldClash(b, a.teacher, a.id)) {
      return TeacherSwapResult.wouldClash;
    }

    _assignments[idxA] = a.copyWith(teacher: b.teacher);
    _assignments[idxB] = b.copyWith(teacher: a.teacher);
    notifyListeners();
    _saveData();
    return TeacherSwapResult.success;
  }

  /// Returns the elective group (if any) that covers [classId] at [timeSlotId].

  ElectiveGroup? electiveGroupFor(String classId, String timeSlotId) {
    return _electiveGroups
        .where(
            (g) => g.timeSlotId == timeSlotId && g.classIds.contains(classId))
        .firstOrNull;
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬ Navigation State for Cross-Screen Tab Switching Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  int _targetDataEntryTab = 0;
  int get targetDataEntryTab => _targetDataEntryTab;

  // When true, the next Firestore snapshot is our own write Ã¢â‚¬â€ skip it
  // so the in-memory fix from fixTeacherClashes isn't overwritten.
  bool _rulesApplied = false; // guard: apply combined rules only once on first load
  bool _hasLoadedData = false; // guard: prevent saving before a successful load

  void setTargetTab(int index) {
    if (_targetDataEntryTab != index) {
      _targetDataEntryTab = index;
      notifyListeners();
    }
  }

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ LOAD ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬

  List _decodeList(dynamic raw) {
    if (raw == null) return [];
    if (raw is String) return jsonDecode(raw) as List;
    if (raw is List) return raw;
    return [];
  }

  // Parses a raw Firestore/backup data map into the in-memory model
  // lists. Shared by the snapshot listener (_loadData) and importBackup()
  // so a restored backup updates the UI immediately instead of waiting on
  // a Firestore round-trip that can stall if the network is slow/offline.
  void _applyData(Map<String, dynamic> data) {
        if (data['departments'] != null) {
          final List decoded = _decodeList(data['departments']);
          _departments.clear();
          _departments.addAll(decoded.map((d) => d as String));
        }

        if (data['teachers'] != null) {
          final List decoded = _decodeList(data['teachers']);
          _teachers.clear();
          _teachers.addAll(decoded.map((d) => Teacher(
              id: d['id'], name: d['name'], department: d['department'])));

          for (final t in _teachers) {
            if (!_departments.contains(t.department.trim()) &&
                t.department.trim().isNotEmpty) {
              _departments.add(t.department.trim());
            }
          }
        }

        if (data['courses'] != null) {
          final List decoded = _decodeList(data['courses']);
          _courses.clear();
          _courses.addAll(decoded.map((d) => Course(
              id: d['id'],
              name: d['name'],
              code: d['code'],
              creditHours: (d['creditHours'] as int?) ?? 3,
              level: d['level'] != null
                  ? EducationLevel.values[d['level'] as int]
                  : EducationLevel.bachelors)));
        }

        if (data['programs'] != null) {
          final List decoded = _decodeList(data['programs']);
          _programs.clear();
          _programs.addAll(decoded.map((d) => ProgramGroup(
              id: d['id'],
              name: d['name'],
              level: d['level'] != null
                  ? EducationLevel.values[d['level'] as int]
                  : EducationLevel.intermediate)));
        }

        if (data['classes'] != null) {
          final List decoded = _decodeList(data['classes']);
          _classes.clear();
          _classes.addAll(decoded.map((d) => ClassModel(
              id: d['id'],
              programId: d['programId'],
              name: d['name'],
              shortCode: d['shortCode'],
              level: d['level'] != null
                  ? EducationLevel.values[d['level'] as int]
                  : EducationLevel.intermediate)));
        }

        if (data['rooms'] != null) {
          final List decoded = _decodeList(data['rooms']);
          _rooms.clear();
          _rooms.addAll(decoded.map((d) => Room(
              id: d['id'],
              name: d['name'],
              type: RoomType.values[d['type'] as int],
              capacity: d['capacity'] as int?)));
        }

        if (data['timeslots'] != null) {
          final List decoded = _decodeList(data['timeslots']);
          _timeSlots.clear();
          _timeSlots.addAll(decoded.map((d) {
            EducationLevel lvl;
            if (d['level'] != null) {
              lvl = EducationLevel.values[d['level'] as int];
            } else {
              // Legacy data: infer from ID prefix
              final id = d['id'] as String? ?? '';
              lvl = id.startsWith('ts_bac')
                  ? EducationLevel.bachelors
                  : EducationLevel.intermediate;
            }
            return TimeSlot(
              id: d['id'],
              period: d['period'] as int,
              startTime: d['startTime'],
              endTime: d['endTime'],
              level: lvl,
              hasFridayOverride: d['hasFridayOverride'] as bool? ?? false,
              fridayStart: d['fridayStart'],
              fridayEnd: d['fridayEnd'],
            );
          }));
        } else {
          _timeSlots.clear();
          _timeSlots.addAll(TimeSlot.defaults(EducationLevel.intermediate));
          _timeSlots.addAll(TimeSlot.defaults(EducationLevel.bachelors));
        }

        if (data['time_slot_locks'] != null) {
          final List decoded = _decodeList(data['time_slot_locks']);
          _timeSlotLocks.clear();
          _timeSlotLocks.addAll(decoded.map((d) => TimeSlotLock.fromJson(d)));
        }

        if (data['combinedRules'] != null) {
          final List decoded = _decodeList(data['combinedRules']);
          _combinedRules.clear();
          _combinedRules
              .addAll(decoded.map((d) => CombinedClassRule.fromJson(d)));
        }

        if (data['electiveGroups'] != null) {
          final List decoded = _decodeList(data['electiveGroups']);
          _electiveGroups.clear();
          _electiveGroups.addAll(decoded
              .map((d) => ElectiveGroup.fromJson(d as Map<String, dynamic>)));
        }

        if (data['shiftRules'] != null) {
          final List decoded = _decodeList(data['shiftRules']);
          _shiftRules.clear();
          _shiftRules.addAll(decoded
              .map((d) => ShiftRule.fromJson(d as Map<String, dynamic>)));
        }

        if (data['teachers'] != null) {
          final List decoded = _decodeList(data['teachers']);
          _teachers.clear();
          // Maps an id to the (lowercased) teacher name that first claimed it.
          // Multiple department-records for the SAME person intentionally
          // share one id (see the dept-split loop below) — that is not
          // corruption. Only flag a collision when a DIFFERENT teacher name
          // reuses an id; otherwise this "fix" re-triggers every load,
          // forever re-saving and re-syncing (observed to crash the app).
          final seenIdToName = <String, String>{};
          final idMap = <String, String>{}; // old_id+name -> new unique id
          bool hadDuplicates = false;

          for (final d in decoded) {
            String id = d['id'];
            final name = d['name'] as String;
            final lowerName = name.toLowerCase();
            if (seenIdToName[id] != null && seenIdToName[id] != lowerName) {
              // Collision detected ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â reassign a fresh unique ID
              final newId = _uid();
              idMap['${id}_$name'] = newId;
              id = newId;
              hadDuplicates = true;
              debugPrint(
                  'Duplicate teacher ID detected for "$name", reassigned to $id');
            }
            seenIdToName[id] = lowerName;
            final rawDept = (d['department'] ?? '') as String;
            // Migration: clean up old persisted combined depts (e.g. "Biology+Botany" or "Pol. Sc HOD")
            var cleanedDept = rawDept.trim();
            cleanedDept = cleanedDept
                .replaceAll(
                    RegExp(r'\bhod\b[\s\.\-]*|[\s\.\-]*\bhod\b',
                        caseSensitive: false),
                    '')
                .trim();
            final deptParts = cleanedDept.isNotEmpty
                ? cleanedDept
                    .split(RegExp(r'[/+]'))
                    .map((p) => p.trim())
                    .where((p) => p.isNotEmpty)
                    .toList()
                : [rawDept.trim()];

            for (final dept in deptParts) {
              // Dedup by name+dept
              final alreadyHave =
                  _teachers.any((t) => t.name == name && t.department == dept);
              if (!alreadyHave) {
                final existing = _teachers
                    .where((t) => t.name.toLowerCase() == name.toLowerCase())
                    .firstOrNull;
                final newId =
                    existing?.id ?? (dept == deptParts.first ? id : _uid());
                _teachers.add(Teacher(id: newId, name: name, department: dept));
              }
            }
          }

          if (data['assignments'] != null) {
            final List decodedAssignments = _decodeList(data['assignments']);
            _assignments.clear();
            for (final d in decodedAssignments) {
              try {
                final tMap = d['teacher'] as Map<String, dynamic>;
                final cMap = d['course'] as Map<String, dynamic>;
                final clMap = d['classModel'] as Map<String, dynamic>;

                String tId = tMap['id'];
                final tName = tMap['name'] as String;
                // Remap teacher ID if it was a duplicate
                if (idMap.containsKey('${tId}_$tName')) {
                  tId = idMap['${tId}_$tName']!;
                }

                final startSlot = d['startSlot'] as int;
                final duration = d['duration'] as int;
                final customDays = List<int>.from(d['customDays'] ?? []);

                // Drop assignments whose days all exceed the 6-day (Mon–Sat) limit
                const maxDay = 6;
                final occupiedDays = customDays.isNotEmpty
                    ? customDays
                    : List.generate(duration, (k) => startSlot + k);
                if (occupiedDays.every((day) => day > maxDay)) continue;

                _assignments.add(Assignment(
                  id: d['id'],
                  teacher: Teacher(
                      id: tId,
                      name: tName,
                      department: tMap['department'] ?? ''),
                  course: Course(
                      id: cMap['id'],
                      name: cMap['name'],
                      code: cMap['code'],
                      creditHours: (cMap['creditHours'] as int?) ?? 3),
                  classModel: ClassModel(
                      id: clMap['id'],
                      programId: clMap['programId'],
                      name: clMap['name'],
                      shortCode: clMap['shortCode'],
                      level: clMap['level'] != null
                          ? EducationLevel.values[clMap['level'] as int]
                          : EducationLevel.intermediate),
                  startSlot: startSlot,
                  duration: duration,
                  timeSlotId: d['timeSlotId'],
                  customDays: customDays,
                  roomId: d['roomId'],
                  autoAssigned: d['autoAssigned'] as bool? ?? false,
                ));
              } catch (e) {
                debugPrint('Skipping corrupt assignment: $e');
              }
            }
          }

          // If we fixed any duplicates, persist the clean data immediately
          if (hadDuplicates) {
            debugPrint('Persisting de-duplicated teacher IDs to Firestore...');
            Future.microtask(() => _saveData());
          }
        }
  }

  void _loadData() {
    _sub = _doc.snapshots().listen((snapshot) {
      _isLoading = false;
      if (!snapshot.exists) {
        _timeSlots.clear();
        _timeSlots.addAll(TimeSlot.defaults(EducationLevel.intermediate));
        _timeSlots.addAll(TimeSlot.defaults(EducationLevel.bachelors));
        Future.microtask(() => notifyListeners());
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>;

      // Skip the local-cache echo of our own write (hasPendingWrites==true) —
      // we already applied this exact state optimistically in memory before
      // calling _saveData(), so there's nothing new to parse here. Always
      // fully process the server-confirmed snapshot (hasPendingWrites==false)
      // instead of relying on a manually-counted "skip N echoes" counter,
      // which drifted out of sync whenever two saves landed close together
      // (or a call site incremented it separately from _saveData()'s own
      // increment) and caused a later, unrelated edit to be silently dropped
      // until some future snapshot happened to arrive.
      // Only skip pending-write echoes once we've already loaded real data
      // once. On the very first load, a stuck/unconfirmed write from a prior
      // session (e.g. the app being closed mid-save) can make every snapshot
      // report hasPendingWrites==true forever — skipping unconditionally
      // here would leave the app permanently stuck showing no data, even
      // though the locally cached document content itself is fine.
      if (snapshot.metadata.hasPendingWrites && _hasLoadedData) {
        return;
      }
      if (_isFixing) {
        return;
      }

      try {
        _applyData(data);
        Future.microtask(() => notifyListeners());

        // Auto-apply combined rules once on first real load (not on echo snapshots).
        // The hasPendingWrites guard above already skips our own echoes, so this
        // only fires for genuine Firestore updates — but we also use _rulesApplied
        // to ensure we only run the heavy merge once per app session.
        if (_combinedRules.isNotEmpty && !_rulesApplied) {
          _rulesApplied = true;
          Future.microtask(() => reApplyAllRules());
        }

        // Auto-evict any assignment sitting in its class's elective slot.
        // Runs after every genuine Firestore update to clean up bad GA data.
        Future.microtask(() => _evictElectiveSlotConflicts());
        
        _hasLoadedData = true;
      } catch (e) {
        debugPrint('Error parsing Firestore data: $e');
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ SAVE ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬

  void _saveData() {
    if (_isLoading || !_hasLoadedData) {
      return;
    }
    _doc.set({
      'departments': jsonEncode(_departments),
      'teachers': jsonEncode(_teachers
          .map((t) => {'id': t.id, 'name': t.name, 'department': t.department})
          .toList()),
      'courses': jsonEncode(_courses
          .map((c) => {
                'id': c.id,
                'name': c.name,
                'code': c.code,
                'creditHours': c.creditHours,
                'level': c.level.index
              })
          .toList()),
      'programs': jsonEncode(_programs
          .map((p) => {'id': p.id, 'name': p.name, 'level': p.level.index})
          .toList()),
      'classes': jsonEncode(_classes
          .map((c) => {
                'id': c.id,
                'programId': c.programId,
                'name': c.name,
                'shortCode': c.shortCode,
                'level': c.level.index
              })
          .toList()),
      'rooms': jsonEncode(_rooms
          .map((r) => {
                'id': r.id,
                'name': r.name,
                'type': r.type.index,
                'capacity': r.capacity
              })
          .toList()),
      'timeslots': jsonEncode(_timeSlots
          .map((ts) => {
                'id': ts.id,
                'period': ts.period,
                'startTime': ts.startTime,
                'endTime': ts.endTime,
                'level': ts.level.index,
                'hasFridayOverride': ts.hasFridayOverride,
                'fridayStart': ts.fridayStart,
                'fridayEnd': ts.fridayEnd
              })
          .toList()),
      'time_slot_locks':
          jsonEncode(_timeSlotLocks.map((l) => l.toJson()).toList()),
      'combinedRules':
          jsonEncode(_combinedRules.map((e) => e.toJson()).toList()),
      'electiveGroups':
          jsonEncode(_electiveGroups.map((g) => g.toJson()).toList()),
      'shiftRules': jsonEncode(_shiftRules.map((r) => r.toJson()).toList()),
      'assignments': jsonEncode(_assignments
          .map((a) => {
                'id': a.id,
                'teacher': {
                  'id': a.teacher.id,
                  'name': a.teacher.name,
                  'department': a.teacher.department
                },
                'course': {
                  'id': a.course.id,
                  'name': a.course.name,
                  'code': a.course.code,
                  'creditHours': a.course.creditHours
                },
                'classModel': {
                  'id': a.classModel.id,
                  'programId': a.classModel.programId,
                  'name': a.classModel.name,
                  'shortCode': a.classModel.shortCode,
                  'level': a.classModel.level.index
                },
                'startSlot': a.startSlot,
                'duration': a.duration,
                'timeSlotId': a.timeSlotId,
                'customDays': a.customDays,
                'roomId': a.roomId,
                'autoAssigned': a.autoAssigned,
              })
          .toList()),
    }, SetOptions(merge: true));
  }

  // NOTE: these fields are plain nested Lists/Maps (not jsonEncode'd
  // strings) so the backup file on disk is genuine structured JSON —
  // openable and readable in any JSON viewer/editor, not an opaque
  // escaped-string blob. Firestore itself still stores these fields as
  // encoded strings internally (see _saveData); _decodeList()/importBackup
  // below accept either shape, so both old and new backup files restore fine.
  Map<String, dynamic> _backupPayload(Map<String, dynamic> settingsData,
      {Map<String, dynamic>? allocatorData}) {
    return {
      'data': {
        'departments': _departments,
        'teachers': _teachers.map((t) => {'id': t.id, 'name': t.name, 'department': t.department}).toList(),
        'courses': _courses.map((c) => {'id': c.id, 'name': c.name, 'code': c.code, 'creditHours': c.creditHours, 'level': c.level.index}).toList(),
        'programs': _programs.map((p) => {'id': p.id, 'name': p.name, 'level': p.level.index}).toList(),
        'classes': _classes.map((c) => {'id': c.id, 'programId': c.programId, 'name': c.name, 'shortCode': c.shortCode, 'level': c.level.index}).toList(),
        'rooms': _rooms.map((r) => {'id': r.id, 'name': r.name, 'type': r.type.index, 'capacity': r.capacity}).toList(),
        'timeslots': _timeSlots.map((ts) => {'id': ts.id, 'period': ts.period, 'startTime': ts.startTime, 'endTime': ts.endTime, 'level': ts.level.index, 'hasFridayOverride': ts.hasFridayOverride, 'fridayStart': ts.fridayStart, 'fridayEnd': ts.fridayEnd}).toList(),
        'time_slot_locks': _timeSlotLocks.map((l) => l.toJson()).toList(),
        'combinedRules': _combinedRules.map((e) => e.toJson()).toList(),
        'electiveGroups': _electiveGroups.map((g) => g.toJson()).toList(),
        'shiftRules': _shiftRules.map((r) => r.toJson()).toList(),
        'assignments': _assignments.map((a) => {
          'id': a.id,
          'teacher': {'id': a.teacher.id, 'name': a.teacher.name, 'department': a.teacher.department},
          'course': {'id': a.course.id, 'name': a.course.name, 'code': a.course.code, 'creditHours': a.course.creditHours},
          'classModel': {'id': a.classModel.id, 'programId': a.classModel.programId, 'name': a.classModel.name, 'shortCode': a.classModel.shortCode, 'level': a.classModel.level.index},
          'startSlot': a.startSlot,
          'duration': a.duration,
          'timeSlotId': a.timeSlotId,
          'customDays': a.customDays,
          'roomId': a.roomId,
          'autoAssigned': a.autoAssigned,
        }).toList(),
      },
      'settings': settingsData,
      if (allocatorData != null) 'allocator': allocatorData,
    };
  }

  Future<void> exportBackup(Map<String, dynamic> settingsData,
      {Map<String, dynamic>? allocatorData}) async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save Backup',
      fileName: 'timetable_backup.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;

    final payload = _backupPayload(settingsData, allocatorData: allocatorData);
    final file = File(path);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }

  /// True once the first Firestore snapshot has loaded — guards autoBackup
  /// (and anything else) from writing before there's real data to save.
  bool get hasLoadedData => _hasLoadedData;

  /// Silent, timer-driven safety net (see dashboard_screen.dart): dumps the
  /// same payload as exportBackup to a local rotating file, no file-picker
  /// dialog. Protects against data loss from the native Firestore crash
  /// found in this app (uncaught exception, 0xe06d7363) — a crash between
  /// manual "Save Backup" clicks previously lost everything since.
  Future<void> autoBackup(Map<String, dynamic> settingsData,
      {Map<String, dynamic>? allocatorData}) async {
    if (!_hasLoadedData) return;
    try {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null) return;
      final dir = Directory('$localAppData\\timetable_maker_app\\backups');
      await dir.create(recursive: true);
      final ts = DateTime.now();
      String p2(int n) => n.toString().padLeft(2, '0');
      final name = 'backup_${ts.year}${p2(ts.month)}${p2(ts.day)}_'
          '${p2(ts.hour)}${p2(ts.minute)}${p2(ts.second)}.json';
      final payload = _backupPayload(settingsData, allocatorData: allocatorData);
      await File('${dir.path}\\$name')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('backup_') &&
              f.uri.pathSegments.last.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      const keep = 10;
      if (files.length > keep) {
        for (final f in files.sublist(0, files.length - keep)) {
          try { await f.delete(); } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('autoBackup failed: $e');
    }
  }

  /// Restores a backup file. Returns the full decoded top-level map so the
  /// caller can also hand the `settings` and `allocator` slices to their
  /// respective view models (this view model only owns the `data` slice).
  Future<Map<String, dynamic>> importBackup() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select Backup File',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.single.path == null) return {};

    final file = File(result.files.single.path!);
    final str = await file.readAsString();
    final decoded = jsonDecode(str) as Map<String, dynamic>;

    // Check if it's the old format (just data) or the new combined format
    Map<String, dynamic> data;

    if (decoded.containsKey('data') && decoded.containsKey('settings')) {
      data = decoded['data'] as Map<String, dynamic>;
    } else {
      data = decoded; // Old backup format
    }

    // Allow saving again (in case it was locked)
    _hasLoadedData = true;

    // Apply the restored data to in-memory state immediately so the UI
    // reflects it right away. Previously this only wrote to Firestore and
    // waited for the snapshot listener to echo it back — but the listener
    // skips the local pending-write echo (hasPendingWrites==true) and only
    // processes the server-confirmed snapshot, so on a slow/offline
    // connection the restore looked like it did nothing until the write
    // finally reached the server (or the app was reopened, which re-fetches
    // fresh from cache/server).
    _applyData(data);
    notifyListeners();

    // Persist in the background — don't block the UI on the network round
    // trip. If this fails, the in-memory state above is still correct; the
    // next edit's _saveData() call will retry persisting the full state.
    unawaited(_doc.set(data, SetOptions(merge: true)).catchError((e) {
      debugPrint('Failed to persist restored backup to Firestore: $e');
    }));

    return decoded;
  }

  // ── Shift Rules ──────────────────────────────────────────────────────────────

  /// Sets or updates the shift for a class. If [shift] is null, the manual
  /// rule is removed and the class falls back to automatic shift assignment.
  void setShiftRule(String classId, String className, ShiftType? shift) {
    _shiftRules.removeWhere((r) => r.classId == classId);
    if (shift != null) {
      _shiftRules.add(ShiftRule(
        id: _uid(),
        classId: classId,
        className: className,
        shift: shift,
      ));
    }
    notifyListeners();
    _saveData();
  }

  void clearShiftRule(String classId) {
    _shiftRules.removeWhere((r) => r.classId == classId);
    notifyListeners();
    _saveData();
  }

  // ── Departments ──────────────────────────────────────────────────────────────

  void addDepartment(String name) {
    if (!_departments.contains(name.trim())) {
      _departments.add(name.trim());
      notifyListeners();
      _saveData();
    }
  }

  void removeDepartment(String name) {
    final teachersToRemove =
        _teachers.where((t) => t.department == name).map((t) => t.id).toList();
    for (final tId in teachersToRemove) {
      removeTeacher(tId);
    }
    notifyListeners();
    _saveData();
  }

  void updateDepartment(String oldName, String newName) {
    final idx = _departments.indexOf(oldName);
    if (idx != -1) {
      _departments[idx] = newName.trim();

      for (int i = 0; i < _teachers.length; i++) {
        if (_teachers[i].department == oldName) {
          _teachers[i] = Teacher(
              id: _teachers[i].id,
              name: _teachers[i].name,
              department: newName.trim());
        }
      }
      for (int i = 0; i < _assignments.length; i++) {
        if (_assignments[i].teacher.department == oldName) {
          _assignments[i] = _assignments[i].copyWith(
            teacher: Teacher(
                id: _assignments[i].teacher.id,
                name: _assignments[i].teacher.name,
                department: newName.trim()),
          );
        }
      }
      notifyListeners();
      _saveData();
    }
  }

  // â”€â”€ Time Slot Locks â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Saves the lock AND immediately moves all matching existing assignments
  /// to the locked time slot so the matrix updates at once â€” no GA needed.
  /// Returns a log of changes made.
  List<String> addTimeSlotLock(TimeSlotLock lock) {
    _timeSlotLocks.add(lock);
    final log = _applyLockToAssignments(lock);
    notifyListeners();
    _saveData();
    return log;
  }

  /// Re-applies every existing Time Slot Lock to the current assignments.
  /// Covers drift where a card matching a lock got re-pinned (e.g. edited
  /// later via the Allocator's manual-period form, which pins BOTH slot and
  /// days even when only the period was meant to be fixed) — this moves it
  /// back to the locked slot and unpins it so Fix Now/GA can arrange its
  /// days again, exactly like adding the lock fresh would.
  List<String> resyncTimeSlotLocks() {
    final log = <String>[];
    for (final lock in _timeSlotLocks) {
      log.addAll(_applyLockToAssignments(lock));
    }
    log.addAll(_destaggerPinnedDuplicates());
    if (log.isNotEmpty) {
      notifyListeners();
      _saveData();
    }
    return log;
  }

  /// Global version of the same fix — not dependent on a Time Slot Lock
  /// existing. Finds any group of pinned (autoAssigned:false) assignments
  /// taught by the SAME TEACHER, sharing the same course+level+period across
  /// DIFFERENT classes, that genuinely overlap on days (e.g. a teacher's
  /// several sections of the same course all landing on identical days by
  /// mistake, same root cause as the locked-course case: the Allocator's
  /// "Manual period, Auto days" combo pins both). Destaggers + unpins them
  /// using the same day-search as `_applyLockToAssignments`, but scoped
  /// strictly to that group's own members — it never relocates anything
  /// from a different period, and never touches an already conflict-free
  /// group. Teacher MUST be part of the key: several different teachers
  /// legitimately teach the same course in the same period to their own
  /// sections on the same days — that's not a clash, and grouping across
  /// teachers previously caused this function to try to cram every section
  /// of a course into a handful of day-windows meant for one teacher only.
  List<String> _destaggerPinnedDuplicates() {
    final groups = <String, List<int>>{};
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      if (a.autoAssigned) continue;
      groups
          .putIfAbsent(
              '${a.teacher.id}|${a.course.id}|${a.classModel.level.index}|${a.timeSlotId}',
              () => [])
          .add(i);
    }

    final log = <String>[];
    for (final idxs in groups.values) {
      if (idxs.length < 2) continue;
      // Same class appearing twice in one period is a different problem
      // (a real duplicate entry) — leave it for the user to resolve.
      final classIds = idxs.map((i) => _assignments[i].classModel.id).toSet();
      if (classIds.length != idxs.length) continue;

      var hasOverlap = false;
      for (int x = 0; x < idxs.length && !hasOverlap; x++) {
        final dx = _assignments[idxs[x]].occupiedSlots.toSet();
        for (int y = x + 1; y < idxs.length; y++) {
          if (dx.intersection(_assignments[idxs[y]].occupiedSlots.toSet()).isNotEmpty) {
            hasOverlap = true;
            break;
          }
        }
      }
      if (!hasOverlap) continue;

      final targetSlot =
          _timeSlots.where((t) => t.id == _assignments[idxs.first].timeSlotId).firstOrNull;
      if (targetSlot == null) continue;

      for (final i in idxs) {
        final a = _assignments[i];
        final ownDays = a.occupiedSlots;
        final dur = ownDays.length.clamp(1, 6);
        List<int>? block;
        if (_areDaysFreeInSlot(
            ownDays, targetSlot, a.teacher.id, a.classModel.id, a.roomId, a.id)) {
          block = ownDays;
        } else {
          for (int start = 1; start + dur - 1 <= 6; start++) {
            final days = List<int>.generate(dur, (k) => start + k);
            if (_areDaysFreeInSlot(
                days, targetSlot, a.teacher.id, a.classModel.id, a.roomId, a.id)) {
              block = days;
              break;
            }
          }
        }
        final keepOwnDays = block == null || identical(block, ownDays);
        _assignments[i] = keepOwnDays
            ? a.copyWith(timeSlotId: targetSlot.id, autoAssigned: true)
            : a.copyWith(
                timeSlotId: targetSlot.id,
                startSlot: block.first,
                duration: block.length,
                customDays: const [],
                autoAssigned: true,
              );
        log.add('[Destagger] ${a.classModel.shortCode}/${a.course.code} '
            'unpinned within ${targetSlot.shortLabel} — run Fix Now / GA to finalise');
      }
    }
    return log;
  }

  List<String> _applyLockToAssignments(TimeSlotLock lock) {
    final log = <String>[];
    final targetSlot =
        _timeSlots.where((t) => t.id == lock.timeSlotId).firstOrNull;
    if (targetSlot == null) return log;

    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      if (a.course.id != lock.courseId) continue;
      if (a.classModel.level != lock.level) continue;
      if (lock.classId != null &&
          lock.classId!.isNotEmpty &&
          a.classModel.id != lock.classId) { continue; }
      // Find a clash-free day-block for this card INSIDE the locked slot.
      // Keeping the original days blindly stacked every section of the same
      // teacher onto identical days and then pinned them there — clashes no
      // solver can fix, since pinned cards freeze slot AND days. Successive
      // cards see earlier moves via _areDaysFreeInSlot (live _assignments),
      // so a teacher's sections stagger automatically (d1-2, d3-4, d5-6).
      final ownDays = a.occupiedSlots;
      final dur = ownDays.length.clamp(1, 6);
      List<int>? block;
      // Prefer keeping the card's current days if they're free in the slot.
      if (_areDaysFreeInSlot(
          ownDays, targetSlot, a.teacher.id, a.classModel.id, a.roomId, a.id)) {
        block = ownDays;
      } else {
        for (int start = 1; start + dur - 1 <= 6; start++) {
          final days = List<int>.generate(dur, (k) => start + k);
          if (_areDaysFreeInSlot(days, targetSlot, a.teacher.id,
              a.classModel.id, a.roomId, a.id)) {
            block = days;
            break;
          }
        }
      }

      // No clash-free block yet? Still move to the locked PERIOD keeping the
      // card's own days — arranging days is the solver's job (see below).
      final keepOwnDays = block == null || identical(block, ownDays);

      // Move to the locked slot but keep the card UNPINNED (autoAssigned:true).
      // CSP/GA enforce the lock via `lockedSlots` REGARDLESS of this flag, and
      // only an unpinned card lets them (a) stagger its days clash-free and
      // (b) relocate the auto courses currently filling the target period,
      // respecting electives/shifts. Pinning froze BOTH slot and days, which
      // deadlocked the solver — the bug this fixes. Successive cards still see
      // earlier moves via _areDaysFreeInSlot, so a first-pass stagger shows
      // immediately; the GA finalises anything the greedy pass couldn't.
      final already =
          a.timeSlotId == lock.timeSlotId && keepOwnDays && a.autoAssigned;
      if (already) continue;
      _assignments[i] = keepOwnDays
          ? a.copyWith(timeSlotId: lock.timeSlotId, autoAssigned: true)
          : a.copyWith(
              timeSlotId: lock.timeSlotId,
              startSlot: block.first,
              duration: block.length,
              customDays: const [],
              autoAssigned: true,
            );
      log.add(
          'Moved ${a.classModel.shortCode}/${a.course.code} to ${lock.timeSlotLabel} — run GA to finalise');
    }
    return log;
  }

  void removeTimeSlotLock(String id) {
    final removed = _timeSlotLocks.where((l) => l.id == id).firstOrNull;
    _timeSlotLocks.removeWhere((l) => l.id == id);

    if (removed != null) {
      final combinedCourseIds = _combinedRules.map((r) => r.courseId).toSet();
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        if (a.course.id != removed.courseId) continue;
        if (removed.classId != null &&
            removed.classId!.isNotEmpty &&
            a.classModel.id != removed.classId) { continue; }
        if (a.autoAssigned) continue;
        final stillLocked = _timeSlotLocks.any((l) =>
            l.courseId == a.course.id &&
            (l.classId == null ||
                l.classId!.isEmpty ||
                l.classId == a.classModel.id));
        final stillCombined = combinedCourseIds.contains(a.course.id);
        if (!stillLocked && !stillCombined) {
          _assignments[i] = a.copyWith(autoAssigned: true);
        }
      }
    }
    _saveData();
    notifyListeners();
  }

  // ── Combined Courses ─────────────────────────────────────────────────────────
  List<String> addCombinedRule(CombinedClassRule rule) {
    _combinedRules.add(rule);
    final log = <String>[];

    // ── 1. Collect best existing assignment per class ────────────────────────
    final Map<String, Assignment> byClassId = {};
    for (final a in _assignments) {
      if (a.course.id == rule.courseId &&
          rule.classIds.contains(a.classModel.id)) {
        final existing = byClassId[a.classModel.id];
        if (existing == null ||
            a.occupiedSlots.length > existing.occupiedSlots.length) {
          byClassId[a.classModel.id] = a;
        }
      }
    }

    if (byClassId.isEmpty) {
      // No existing assignments â€” just save the rule for future assignments.
      log.add(
          'Rule saved. Assign the course to any class; siblings will auto-combine.');
      _saveData();
      notifyListeners();
      return log;
    }

    // â”€â”€ 2. Pick anchor: class with the most occupied days â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Pick anchor: prefer an already-locked assignment; fallback: most days
    final lockedCIds = _timeSlotLocks.map((l) => l.courseId).toSet();
    Assignment anchor = byClassId.values.reduce(
        (a, b) => a.occupiedSlots.length >= b.occupiedSlots.length ? a : b);
    for (final a in byClassId.values) {
      if (!a.autoAssigned && lockedCIds.contains(a.course.id)) {
        anchor = a;
        break;
      }
    }
    // Pin anchor so GA/Fix Now won't move it
    final ancIdx = _assignments.indexWhere((x) => x.id == anchor.id);
    if (ancIdx != -1 && _assignments[ancIdx].autoAssigned) {
      _assignments[ancIdx] =
          _assignments[ancIdx].copyWith(autoAssigned: false);
      anchor = _assignments[ancIdx];
    }

    log.add('Anchor: ${anchor.classModel.shortCode} @ '
        '${anchor.timeSlotId} days=${anchor.occupiedSlots}');

    // â”€â”€ 3. FORCE-move all non-anchor existing assignments to match anchor â”€â”€â”€â”€â”€â”€
    // Combined classes share the SAME slot/days/teacher/room by definition.
    for (final entry in byClassId.entries) {
      if (entry.key == anchor.classModel.id) continue;
      final a = entry.value;
      final idx = _assignments.indexWhere((x) => x.id == a.id);
      if (idx == -1) continue;

      if (a.timeSlotId == anchor.timeSlotId &&
          a.startSlot == anchor.startSlot &&
          a.duration == anchor.duration &&
          a.customDays.join() == anchor.customDays.join()) {
        log.add('${a.classModel.shortCode} already in sync.');
        continue;
      }

      // Sync to anchor AND pin so GA keeps the group together
      _assignments[idx] = a.copyWith(
        timeSlotId: anchor.timeSlotId,
        startSlot: anchor.startSlot,
        duration: anchor.duration,
        customDays: List<int>.from(anchor.customDays),
        teacher: anchor.teacher,
        roomId: anchor.roomId,
        autoAssigned: false,
      );
      log.add('Moved ${a.classModel.shortCode} â†’ '
          '${anchor.timeSlotId} days=${anchor.occupiedSlots}');
    }

    // â”€â”€ 4. Auto-create assignments for classes with no assignment yet â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    for (final classId in rule.classIds) {
      if (byClassId.containsKey(classId)) continue;
      final cls = _classes.where((c) => c.id == classId).firstOrNull;
      if (cls == null) continue;

      // Created sibling — pinned so GA keeps it with the group
      _assignments.add(Assignment(
        id: _uid(),
        teacher: anchor.teacher,
        course: anchor.course,
        classModel: cls,
        startSlot: anchor.startSlot,
        duration: anchor.duration,
        timeSlotId: anchor.timeSlotId,
        customDays: List<int>.from(anchor.customDays),
        roomId: anchor.roomId,
        autoAssigned: false, // pinned — GA must not scatter this
      ));
      log.add('Created for ${cls.shortCode} @ ${anchor.timeSlotId} '
          'days=${anchor.occupiedSlots} (teacher: ${anchor.teacher.name})');
    }

    // ── Persist & notify ─────────────────────────────────────────────────────────
    notifyListeners();
    _saveData();
    return log;
  }

  void removeCombinedRule(String ruleId) {
    final removed = _combinedRules.where((r) => r.id == ruleId).firstOrNull;
    _combinedRules.removeWhere((r) => r.id == ruleId);

    if (removed != null) {
      final lockedCourseIds = _timeSlotLocks.map((l) => l.courseId).toSet();
      final stillCombinedIds = _combinedRules.map((r) => r.courseId).toSet();
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        if (a.course.id != removed.courseId) continue;
        if (!removed.classIds.contains(a.classModel.id)) continue;
        if (a.autoAssigned) continue;
        final stillLocked = lockedCourseIds.contains(a.course.id);
        final stillCombined = stillCombinedIds.contains(a.course.id);
        if (!stillLocked && !stillCombined) {
          _assignments[i] = a.copyWith(autoAssigned: true);
        }
      }
    }
    _saveData();
    notifyListeners();
  }

  // Re-applies ALL existing time slot locks AND combined rules to the current
  // assignments. FORCE mode — no clash checks. The user explicitly set these
  // rules so we honour them unconditionally. Returns total assignments moved.
  int reApplyAllRules() {
    int moved = 0;

    // ── Step 1: Force-apply every time slot lock ──────────────────────────────
    // Match by courseId only + optional classId; ignore level (trust the lock)
    for (final lock in _timeSlotLocks) {
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        if (a.course.id != lock.courseId) continue;
        if (lock.classId != null &&
            lock.classId!.isNotEmpty &&
            a.classModel.id != lock.classId) { continue; }
        if (a.timeSlotId == lock.timeSlotId) {
          if (a.autoAssigned) _assignments[i] = a.copyWith(autoAssigned: false);
          continue;
        }
        _assignments[i] =
            a.copyWith(timeSlotId: lock.timeSlotId, autoAssigned: false);
        moved++;
      }
    }

    // ── Step 2: Force-align every combined rule ───────────────────────────────
    for (final rule in _combinedRules) {
      final byClassId = <String, Assignment>{};
      for (final a in _assignments) {
        if (a.course.id != rule.courseId) continue;
        if (!rule.classIds.contains(a.classModel.id)) continue;
        final existing = byClassId[a.classModel.id];
        if (existing == null ||
            a.occupiedSlots.length > existing.occupiedSlots.length) {
          byClassId[a.classModel.id] = a;
        }
      }
      if (byClassId.length < 2) continue;

      // Prefer the assignment already at a locked slot as anchor
      Assignment anchor = byClassId.values.first;
      for (final lock in _timeSlotLocks) {
        if (lock.courseId != rule.courseId) continue;
        for (final a in byClassId.values) {
          if (a.timeSlotId == lock.timeSlotId) {
            anchor = a;
            break;
          }
        }
        break;
      }

      // Force-move every other class to the anchor slot+days
      for (final entry in byClassId.entries) {
        if (entry.key == anchor.classModel.id) continue;
        final a = entry.value;
        if (a.timeSlotId == anchor.timeSlotId &&
            a.occupiedSlots.toSet().containsAll(anchor.occupiedSlots) &&
            anchor.occupiedSlots.toSet().containsAll(a.occupiedSlots)) {
          continue; // already matches
        }
        final idx = _assignments.indexWhere((x) => x.id == a.id);
        if (idx == -1) continue;
        _assignments[idx] = a.copyWith(
          timeSlotId: anchor.timeSlotId,
          startSlot: anchor.startSlot,
          duration: anchor.duration,
          customDays: List<int>.from(anchor.customDays),
          // Rooms are manual-only — never overwritten by rule alignment.
          teacher: anchor.teacher,
          autoAssigned: false,
        );
        moved++;
      }
    }

    // Step 3 (auto fixTeacherClashes) removed: it ran on every load and
    // silently mutated live data (moved/split assignments per launch).
    // Clash fixing is manual-only now, via the Fix Now button.
    if (moved > 0) {
      notifyListeners();
      _saveData();
    }
    return moved;
  }

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Bulk Import ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
  /// Returns an [ImportData] with counts of what was added, or throws.
  ImportResult bulkImport(ImportData data) {
    int depts = 0, teachers = 0, courses = 0, classes = 0, rooms = 0;
    // ── Departments ──────────────────────────────────────────────────────────────
    for (final dept in data.departments) {
      if (!_departments.contains(dept.trim()) && dept.trim().isNotEmpty) {
        _departments.add(dept.trim());
        depts++;
      }
    }

    // ── Teachers ─────────────────────────────────────────────────────────────────
    // A teacher's department may be "Botany / Biology" (two depts joined with /).
    // Split and create ONE entry per department so the teacher appears under both.
    for (final t in data.teachers) {
      // Split on "/" — handles "Botany / Biology", "Arabic/Urdu", etc.
      final deptList = t.department.contains('/')
          ? t.department
              .split('/')
              .map((d) => d.trim())
              .where((d) => d.isNotEmpty)
              .toList()
          : [t.department.trim()];

      for (final dept in deptList) {
        final alreadyExists = _teachers.any((e) =>
            e.name.toLowerCase() == t.name.toLowerCase() &&
            e.department.toLowerCase() == dept.toLowerCase());
        if (!alreadyExists) {
          final existing = _teachers
              .where((e) => e.name.toLowerCase() == t.name.toLowerCase())
              .firstOrNull;
          _teachers.add(Teacher(
              id: existing?.id ?? _uid(), name: t.name, department: dept));
          teachers++;
        }
      }
    }

    // ── Courses ──────────────────────────────────────────────────────────────────
    for (final c in data.courses) {
      // Determine which level(s) to import under
      final levels = c.level == 'intermediate'
          ? [EducationLevel.intermediate]
          : c.level == 'bachelors'
              ? [EducationLevel.bachelors]
              : [
                  EducationLevel.intermediate,
                  EducationLevel.bachelors
                ]; // unknown → both

      for (final lvl in levels) {
        final alreadyExists = _courses.any((e) =>
            e.code.toLowerCase() == c.code.toLowerCase() && e.level == lvl);
        if (!alreadyExists) {
          _courses.add(Course(
              id: _uid(),
              name: c.name,
              code: c.code,
              creditHours: c.creditHours,
              level: lvl));
          courses++;
        }
      }
    }

    // ── Classes ───────────────────────────────────────────────────────────────────
    for (final cls in data.classes) {
      // Resolve level — if unknown, default to intermediate
      final lvl = cls.level == 'bachelors'
          ? EducationLevel.bachelors
          : EducationLevel.intermediate;

      // Find or create the program
      final progNameLower = cls.program.trim().toLowerCase();
      var prog = _programs
          .where((p) => p.name.toLowerCase() == progNameLower && p.level == lvl)
          .firstOrNull;
      if (prog == null) {
        prog = ProgramGroup(id: _uid(), name: cls.program.trim(), level: lvl);
        _programs.add(prog);
      }

      // Add the class if not already present under this program
      final clsNameLower = cls.className.trim().toLowerCase();
      final alreadyExists = _classes.any((c) =>
          c.programId == prog!.id && c.name.toLowerCase() == clsNameLower);
      if (!alreadyExists) {
        final shortCode = '${prog.name}-${cls.className.trim()}';
        _classes.add(ClassModel(
            id: _uid(),
            programId: prog.id,
            name: cls.className.trim(),
            shortCode: shortCode,
            level: lvl));
        classes++;
      }
    }

    // ── Rooms ─────────────────────────────────────────────────────────────────────
    for (final r in data.rooms) {
      final nameLower = r.name.trim().toLowerCase();
      final alreadyExists =
          _rooms.any((room) => room.name.toLowerCase() == nameLower);
      if (!alreadyExists) {
        _rooms.add(Room(
            id: _uid(),
            name: r.name.trim(),
            type: RoomType.room)); // default to 'room', capacity optional
        rooms++;
      }
    }

    notifyListeners();
    _saveData();
    return ImportResult(
        departments: depts,
        teachers: teachers,
        courses: courses,
        classes: classes,
        rooms: rooms,
        warnings: data.warnings);
  }

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Teachers ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
  void addTeacher(String name, {String department = ''}) {
    final cleanName = name.trim();
    final cleanDept = department.trim();
    final existing = _teachers
        .where((t) => t.name.toLowerCase() == cleanName.toLowerCase())
        .firstOrNull;

    _teachers.add(Teacher(
        id: existing?.id ?? _uid(), name: cleanName, department: cleanDept));
    notifyListeners();
    _saveData();
  }

  // Removes a class ID from all elective group classIds and removes entries
  // matching a deleted course/teacher. Drops any group that becomes invalid
  // (fewer than 2 classes remaining, or no entries remaining).
  void _cleanElectiveGroups(
      {Set<String>? classIds, String? courseId, String? teacherId}) {
    for (int i = _electiveGroups.length - 1; i >= 0; i--) {
      ElectiveGroup g = _electiveGroups[i];

      if (classIds != null && classIds.isNotEmpty) {
        final updated =
            g.classIds.where((id) => !classIds.contains(id)).toList();
      if (updated.length != g.classIds.length) {
          g = g.copyWith(classIds: updated);
        }
      }

      List<ElectiveEntry> entries = g.entries;
      if (courseId != null) {
        entries = entries.where((e) => e.courseId != courseId).toList();
      }
      if (teacherId != null) {
        entries = entries.where((e) => e.teacherId != teacherId).toList();
      }
      if (entries.length != g.entries.length) g = g.copyWith(entries: entries);

      if (g.classIds.length < 2 || g.entries.isEmpty) {
        _electiveGroups.removeAt(i);
      } else {
        _electiveGroups[i] = g;
      }
    }
  }

  void removeTeacher(String id) {
    _cleanElectiveGroups(teacherId: id);
    _teachers.removeWhere((t) => t.id == id);
    _assignments.removeWhere((a) => a.teacher.id == id);
    notifyListeners();
    _saveData();
  }

  void updateTeacher(String id, String name, {String department = ''}) {
    final idx = _teachers.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _teachers[idx] =
          Teacher(id: id, name: name.trim(), department: department.trim());
      notifyListeners();
      _saveData();
    }
  }

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Courses ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
  /// Returns false (and adds nothing) if a course with the same code already
  /// exists at this level — duplicate course records defeat every
  /// duplicate-assignment check downstream, which all match by course id.
  bool addCourse(String name, String code,
      {int creditHours = 3, EducationLevel level = EducationLevel.bachelors}) {
    final norm = code.trim().toUpperCase();
    if (_courses.any((c) => c.code == norm && c.level == level)) return false;
    _courses.add(Course(
        id: _uid(),
        name: name.trim(),
        code: norm,
        creditHours: creditHours,
        level: level));
    notifyListeners();
    _saveData();
    return true;
  }

  void removeCourse(String id) {
    _cleanElectiveGroups(courseId: id);
    _courses.removeWhere((c) => c.id == id);
    _assignments.removeWhere((a) => a.course.id == id);
    notifyListeners();
    _saveData();
  }

  /// Returns false (and changes nothing) if the new code would collide with
  /// another course at this level.
  bool updateCourse(String id, String name, String code,
      {int creditHours = 3, EducationLevel level = EducationLevel.bachelors}) {
    final norm = code.trim().toUpperCase();
    if (_courses.any((c) => c.id != id && c.code == norm && c.level == level)) {
      return false;
    }
    final idx = _courses.indexWhere((c) => c.id == id);
    if (idx != -1) {
      _courses[idx] = Course(
          id: id,
          name: name.trim(),
          code: norm,
          creditHours: creditHours,
          level: level);
      notifyListeners();
      _saveData();
    }
    return true;
  }

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Programs ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
  void addProgram(String name, EducationLevel level) {
    _programs.add(ProgramGroup(id: _uid(), name: name.trim(), level: level));
    notifyListeners();
    _saveData();
  }

  void removeProgram(String id) {
    final classIds =
        _classes.where((c) => c.programId == id).map((c) => c.id).toSet();
    _cleanElectiveGroups(classIds: classIds);
    _programs.removeWhere((p) => p.id == id);
    _classes.removeWhere((c) => c.programId == id);
    _assignments.removeWhere((a) => classIds.contains(a.classModel.id));
    notifyListeners();
    _saveData();
  }

  Set<String> classIdsForProgram(String programId) =>
      _classes.where((c) => c.programId == programId).map((c) => c.id).toSet();

  void updateProgram(String id, String name, EducationLevel level) {
    final idx = _programs.indexWhere((p) => p.id == id);
    if (idx != -1) {
      _programs[idx] = ProgramGroup(id: id, name: name.trim(), level: level);
      notifyListeners();
      _saveData();
    }
  }

  List<ClassModel> classesForProgram(String programId) =>
      _classes.where((c) => c.programId == programId).toList();

  // ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Classes ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
  void addClass(String programId, String name) {
    final prog = _programs.firstWhere((p) => p.id == programId,
        orElse: () =>
            ProgramGroup(id: '', name: '', level: EducationLevel.intermediate));
    final code = '${prog.name}-${name.trim()}';
    _classes.add(ClassModel(
        id: _uid(),
        programId: programId,
        name: name.trim(),
        shortCode: code,
        level: prog.level));
    notifyListeners();
    _saveData();
  }

  void removeClass(String id) {
    _cleanElectiveGroups(classIds: {id});
    _classes.removeWhere((c) => c.id == id);
    _assignments.removeWhere((a) => a.classModel.id == id);
    notifyListeners();
    _saveData();
  }

  void updateClass(String id, String programId, String name) {
    final idx = _classes.indexWhere((c) => c.id == id);
    if (idx != -1) {
      final prog = _programs.firstWhere((p) => p.id == programId,
          orElse: () => ProgramGroup(
              id: '', name: '', level: EducationLevel.intermediate));
      final code = '${prog.name}-${name.trim()}';
      _classes[idx] = ClassModel(
          id: id,
          programId: programId,
          name: name.trim(),
          shortCode: code,
          level: prog.level);
      notifyListeners();
      _saveData();
    }
  }

  // ──────────────────────────────── Rooms ────────────────────────────────
  void addRoom(String name, RoomType type, {int? capacity}) {
    _rooms.add(
        Room(id: _uid(), name: name.trim(), type: type, capacity: capacity));
    notifyListeners();
    _saveData();
  }

  void removeRoom(String id) {
    _rooms.removeWhere((r) => r.id == id);
    // Cascade: clear the deleted room off every assignment so no stale
    // reference is left to show phantom rows/clashes in room views.
    for (int i = 0; i < _assignments.length; i++) {
      if (_assignments[i].roomId == id) {
        _assignments[i] = Assignment(
          id: _assignments[i].id,
          teacher: _assignments[i].teacher,
          course: _assignments[i].course,
          classModel: _assignments[i].classModel,
          startSlot: _assignments[i].startSlot,
          duration: _assignments[i].duration,
          timeSlotId: _assignments[i].timeSlotId,
          customDays: _assignments[i].customDays,
          roomId: null,
          autoAssigned: _assignments[i].autoAssigned,
        );
      }
    }
    notifyListeners();
    _saveData();
  }

  void updateRoom(String id, String name, RoomType type, {int? capacity}) {
    final idx = _rooms.indexWhere((r) => r.id == id);
    if (idx != -1) {
      _rooms[idx] =
          Room(id: id, name: name.trim(), type: type, capacity: capacity);
      notifyListeners();
      _saveData();
    }
  }

  // ──────────────────────────────── Time Slots ────────────────────────────────
  void addTimeSlot(String startTime, String endTime, EducationLevel level) {
    final levelSlots = _timeSlots.where((t) => t.level == level).toList();
    final period = levelSlots.isEmpty ? 1 : levelSlots.last.period + 1;
    _timeSlots.add(TimeSlot(
        id: _uid(),
        period: period,
        startTime: startTime,
        endTime: endTime,
        level: level));
    notifyListeners();
    _saveData();
  }

  /// Renumbers one level's periods to match actual chronological order.
  /// addTimeSlot always appends (period = last + 1), so importing a file
  /// whose periods partially reuse existing start times (e.g. a new
  /// evening-shift period landing between two long-unused default slots)
  /// leaves .period values that no longer reflect clock order — sort
  /// callers throughout the app already rely on .period, and headers
  /// display it directly ("P7" sitting between "P4" and "P5"), so this
  /// keeps that invariant true instead of just working around it per call
  /// site.
  void renumberTimeSlotsChronologically(EducationLevel level) {
    int mins(String t) {
      final p = t.split(':');
      if (p.length != 2) return 0;
      return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
    }

    final levelSlots = _timeSlots.where((t) => t.level == level).toList()
      ..sort((a, b) => mins(a.startTime).compareTo(mins(b.startTime)));
    for (int i = 0; i < levelSlots.length; i++) {
      final slotIdx = _timeSlots.indexOf(levelSlots[i]);
      _timeSlots[slotIdx] = _timeSlots[slotIdx].copyWith(period: i + 1);
    }
    notifyListeners();
    _saveData();
  }

  void removeTimeSlot(String id) {
    final idx = _timeSlots.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    final level = _timeSlots[idx].level;
    _timeSlots.removeAt(idx);

    final levelSlots = _timeSlots.where((t) => t.level == level).toList();
    for (int i = 0; i < levelSlots.length; i++) {
      final slotIdx = _timeSlots.indexOf(levelSlots[i]);
      _timeSlots[slotIdx] = _timeSlots[slotIdx].copyWith(period: i + 1);
    }
    notifyListeners();
    _saveData();
  }

  void updateTimeSlot(String id,
      {String? startTime,
      String? endTime,
      bool? hasFridayOverride,
      String? fridayStart,
      String? fridayEnd}) {
    final idx = _timeSlots.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    _timeSlots[idx] = _timeSlots[idx].copyWith(
        startTime: startTime,
        endTime: endTime,
        hasFridayOverride: hasFridayOverride,
        fridayStart: fridayStart,
        fridayEnd: fridayEnd);
    notifyListeners();
    _saveData();
  }

  // ──────────────────────────────── Assignments ────────────────────────────────

  // -- Assignments --
  void addAssignment({
    required Teacher teacher,
    required Course course,
    required ClassModel classModel,
    required int startSlot,
    required int duration,
    required String timeSlotId,
    List<int> customDays = const [],
    String? roomId,
    bool autoAssigned = false,
  }) {
    _assignments.add(Assignment(
      id: _uid(),
      teacher: teacher,
      course: course,
      classModel: classModel,
      startSlot: startSlot,
      duration: duration,
      timeSlotId: timeSlotId,
      customDays: customDays,
      roomId: roomId,
      autoAssigned: autoAssigned,
    ));
    notifyListeners();
    _saveData();
  }

  void removeAssignment(String id) {
    _assignments.removeWhere((a) => a.id == id);
    notifyListeners();
    _saveData();
  }

  // ── One-step undo ────────────────────────────────────────────────────────
  // Depth-1 safety net for the multi-card operations (make-space, force-
  // assign-with-clash, Fix Now, Suggest-Fix apply): each of those calls
  // snapshotForUndo() right before it mutates. A second risky action simply
  // overwrites the one saved snapshot — no history stack, by design.
  List<Assignment>? _undoSnapshot;
  String? _undoLabel;
  Timer? _undoTimer;

  bool get canUndo => _undoSnapshot != null;
  String? get undoLabel => _undoLabel;

  void snapshotForUndo(String label) {
    _undoSnapshot = List<Assignment>.from(_assignments);
    _undoLabel = label;
    _undoTimer?.cancel();
    _undoTimer = Timer(const Duration(seconds: 5), () {
      _undoSnapshot = null;
      _undoLabel = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void undoLastChange() {
    if (_undoSnapshot == null) return;
    _assignments
      ..clear()
      ..addAll(_undoSnapshot!);
    _undoSnapshot = null;
    _undoLabel = null;
    _undoTimer?.cancel();
    notifyListeners();
    _saveData();
  }

  /// Removes surplus duplicate assignments — same course + same class
  /// appearing more times than the course's credit hours allow.
  /// The GA/CSP can NEVER fix these: duplicates aren't "clashes" by the
  /// engine's rules (same course ≠ section clash), they just silently eat
  /// double the teacher's weekly capacity and cascade teacher clashes
  /// everywhere else. This is a data repair, done here deterministically:
  /// keep pinned (autoAssigned=false) copies first, then the fewest-days
  /// copies, dropping whole surplus assignments until within credit budget.
  /// Returns log lines describing what was removed.
  List<String> removeDuplicateAssignments() {
    final log = <String>[];
    final Map<String, List<Assignment>> byKey = {};
    for (final a in _assignments) {
      byKey.putIfAbsent('${a.course.id}__${a.classModel.id}', () => []).add(a);
    }

    final toRemove = <String>{};
    for (final entry in byKey.entries) {
      final group = entry.value;
      if (group.length < 2) continue; // single assignment can't be a duplicate
      final expected = group.first.course.creditHours;
      int total = group.fold<int>(0, (s, a) => s + a.occupiedSlots.length);
      if (total <= expected) continue; // within budget

      // Priority to KEEP: pinned first, then fewer days (surgical trim),
      // then stable by id for determinism.
      final ordered = List<Assignment>.of(group)
        ..sort((x, y) {
          if (x.autoAssigned != y.autoAssigned) {
            return x.autoAssigned ? 1 : -1; // pinned (false) first
          }
          final dx = x.occupiedSlots.length, dy = y.occupiedSlots.length;
          if (dx != dy) return dx.compareTo(dy);
          return x.id.compareTo(y.id);
        });

      // Keep from the front while budget allows; mark the rest for removal.
      int kept = 0;
      for (final a in ordered) {
        final days = a.occupiedSlots.length;
        if (kept + days <= expected || kept == 0) {
          // Always keep at least one assignment even if it alone exceeds
          // the budget (that's a days-config problem, not a duplicate).
          kept += days;
        } else {
          toRemove.add(a.id);
          log.add('Removed duplicate: ${a.course.code} → ${a.classModel.shortCode} '
              '(${a.teacher.name}, $days day${days > 1 ? 's' : ''})');
        }
      }
    }

    if (toRemove.isNotEmpty) {
      _assignments.removeWhere((a) => toRemove.contains(a.id));
      notifyListeners();
      _saveData();
    }
    return log;
  }

  /// Sets (or clears, when [roomId] is null) the room for an existing
  /// assignment. Used by the standalone Room Allocation UI — rooms are
  /// manual-only, never touched by the GA. Bypasses Assignment.copyWith,
  /// whose `roomId` param uses `roomId ?? this.roomId` and so cannot express
  /// "clear the room"; this constructs the replacement directly instead.
  void setAssignmentRoom(String assignmentId, String? roomId) {
    final idx = _assignments.indexWhere((a) => a.id == assignmentId);
    if (idx == -1) return;
    final a = _assignments[idx];
    _assignments[idx] = Assignment(
      id: a.id,
      teacher: a.teacher,
      course: a.course,
      classModel: a.classModel,
      startSlot: a.startSlot,
      duration: a.duration,
      timeSlotId: a.timeSlotId,
      customDays: a.customDays,
      roomId: roomId,
      autoAssigned: a.autoAssigned,
    );
    notifyListeners();
    _saveData();
  }

  /// Clears the room on every assignment whose roomId no longer resolves to
  /// a room in the current room list (stale reference left behind by a
  /// deleted room — removeRoom() doesn't cascade to clear it). Returns how
  /// many assignments were cleared.
  int clearUnknownRoomAllocations() {
    final validIds = _rooms.map((r) => r.id).toSet();
    var cleared = 0;
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      if (a.hasRoom && !validIds.contains(a.roomId)) {
        _assignments[i] = Assignment(
          id: a.id,
          teacher: a.teacher,
          course: a.course,
          classModel: a.classModel,
          startSlot: a.startSlot,
          duration: a.duration,
          timeSlotId: a.timeSlotId,
          customDays: a.customDays,
          roomId: null,
          autoAssigned: a.autoAssigned,
        );
        cleared++;
      }
    }
    if (cleared > 0) {
      notifyListeners();
      _saveData();
    }
    return cleared;
  }

  /// Releases every manual pin (autoAssigned=false → true) so the scheduler
  /// is free to move all assignments. Explicit TimeSlotLocks and room
  /// allocations are untouched — this only clears the per-assignment
  /// "preserve my exact day/slot" flag. Returns how many were unpinned.
  int unpinAllAssignments() {
    var changed = 0;
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      if (!a.autoAssigned) {
        _assignments[i] = a.copyWith(autoAssigned: true);
        changed++;
      }
    }
    if (changed > 0) {
      notifyListeners();
      _saveData();
    }
    return changed;
  }

  void setLockStateForLevel(EducationLevel level, bool locked) {
    bool changed = false;
    for (int i = 0; i < _assignments.length; i++) {
      if (_assignments[i].classModel.level == level && _assignments[i].autoAssigned == locked) {
        _assignments[i] = _assignments[i].copyWith(autoAssigned: !locked);
        changed = true;
      }
    }
    if (changed) { notifyListeners(); _saveData(); }
  }

  void setLockStateForProgram(String programId, bool locked) {
    bool changed = false;
    for (int i = 0; i < _assignments.length; i++) {
      if (_assignments[i].classModel.programId == programId && _assignments[i].autoAssigned == locked) {
        _assignments[i] = _assignments[i].copyWith(autoAssigned: !locked);
        changed = true;
      }
    }
    if (changed) { notifyListeners(); _saveData(); }
  }

  void setLockStateForClass(String classId, bool locked) {
    bool changed = false;
    for (int i = 0; i < _assignments.length; i++) {
      if (_assignments[i].classModel.id == classId && _assignments[i].autoAssigned == locked) {
        _assignments[i] = _assignments[i].copyWith(autoAssigned: !locked);
        changed = true;
      }
    }
    if (changed) { notifyListeners(); _saveData(); }
  }

  void clearAllData() {
    _departments.clear();
    _teachers.clear();
    _courses.clear();
    _programs.clear();
    _classes.clear();
    _rooms.clear();
    _timeSlots.clear();
    _timeSlots.addAll(TimeSlot.defaults(EducationLevel.intermediate));
    _timeSlots.addAll(TimeSlot.defaults(EducationLevel.bachelors));
    _timeSlotLocks.clear();
    _assignments.clear();
    _combinedRules.clear();
    // Elective groups/entries reference teacher/course/class ids that are
    // being wiped above — leaving them behind made combinedAssignments()
    // synthesize phantom assignments that all fell back to the same empty
    // placeholder class id, so they all "clashed" with each other even
    // though the schedule was empty (e.g. reported "5899 clashes found").
    _electiveGroups.clear();
    _shiftRules.clear();
    notifyListeners();
    _saveData();
  }

  Set<int> occupiedSlotsForTeacher(String teacherId, String timeSlotId) {
    final result = <int>{};
    for (final a in _assignments) {
      if (a.teacher.id == teacherId && a.timeSlotId == timeSlotId) {
        result.addAll(a.occupiedSlots);
      }
    }
    return result;
  }

  Set<String> occupiedTimeSlotIdsForTeacher(String teacherId, int daySlot) =>
      _assignments
          .where((a) =>
              a.teacher.id == teacherId && a.occupiedSlots.contains(daySlot))
          .map((a) => a.timeSlotId)
          .toSet();

  /// Which time-slot IDs does [classId] already have a course in on [daySlot]?
  Set<String> occupiedTimeSlotIdsForClass(String classId, int daySlot) =>
      _assignments
          .where((a) =>
              a.classModel.id == classId && a.occupiedSlots.contains(daySlot))
          .map((a) => a.timeSlotId)
          .toSet();

  /// How many days of [timeSlotId] are already consumed by [classId]?
  /// Max allowed = workingDays (prevents over-booking a slot for the same class).
  Set<int> occupiedDaysForClassInSlot(String classId, String timeSlotId) =>
      _assignments
          .where(
              (a) => a.classModel.id == classId && a.timeSlotId == timeSlotId)
          .expand((a) => a.occupiedSlots)
          .toSet();

  /// Read-only structural sanity scan of the assignment data. Flags records
  /// whose day data is corrupted (out-of-range days, duplicates, duration vs
  /// custom-days mismatch — e.g. the startSlot 3 + duration 6 case that
  /// produced days [3,4,5,6,6,6]) or whose time slot no longer exists.
  /// Never modifies anything; pair with [fixDataSanityIssues].
  List<String> dataSanityIssues({int workingDays = 6}) {
    final issues = <String>[];
    final slotIds = timeSlots.map((t) => t.id).toSet();
    for (final a in _assignments) {
      final days = a.occupiedSlots;
      final label =
          '${a.course.code} (${a.classModel.shortCode}, ${a.teacher.name})';
      if (!slotIds.contains(a.timeSlotId)) {
        issues.add(
            '$label: time slot "${a.timeSlotId}" no longer exists — reassign manually.');
      }
      if (days.isEmpty) {
        issues.add('$label: has no scheduled days at all.');
      } else if (days.any((d) => d < 1 || d > workingDays)) {
        issues.add(
            '$label: days ${days.join(',')} fall outside 1-$workingDays.');
      } else if (days.toSet().length != days.length) {
        issues.add('$label: duplicate days ${days.join(',')}.');
      } else if (a.customDays.isNotEmpty &&
          a.customDays.length != a.duration) {
        issues.add(
            '$label: duration ${a.duration} does not match its custom days ${a.customDays.join(',')}.');
      }
    }
    return issues;
  }

  /// Normalizes the day data of every record [dataSanityIssues] flags for a
  /// DAY problem (dangling time slots are left for manual repair). Explicit
  /// user action only — never called automatically. Keeps the record's
  /// in-range days where possible, otherwise rebuilds a contiguous block of
  /// the intended duration clamped inside 1..workingDays. Returns per-record
  /// change messages; caller should re-check clashes afterwards.
  /// Pure day-normalization used by [fixDataSanityIssues]; static so it can
  /// be unit-tested without a Firebase-backed viewmodel. Keeps the record's
  /// distinct in-range days if enough exist, else rebuilds a contiguous
  /// block of the intended duration clamped inside 1..workingDays.
  static List<int> normalizeDayBlock({
    required List<int> days,
    required int startSlot,
    required int duration,
    required int workingDays,
  }) {
    final n = duration.clamp(1, workingDays).toInt();
    final inRange = days
        .where((d) => d >= 1 && d <= workingDays)
        .toSet()
        .toList()
      ..sort();
    if (inRange.length >= n) return inRange.sublist(0, n);
    final start = startSlot.clamp(1, workingDays - n + 1).toInt();
    return List.generate(n, (k) => start + k);
  }

  List<String> fixDataSanityIssues({int workingDays = 6}) {
    final fixed = <String>[];
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      final days = a.occupiedSlots;
      final dayProblem = days.isEmpty ||
          days.any((d) => d < 1 || d > workingDays) ||
          days.toSet().length != days.length ||
          (a.customDays.isNotEmpty && a.customDays.length != a.duration);
      if (!dayProblem) continue;
      final newDays = normalizeDayBlock(
          days: days,
          startSlot: a.startSlot,
          duration: a.duration,
          workingDays: workingDays);
      final consec = newDays.length < 2 ||
          newDays.last - newDays.first == newDays.length - 1;
      _assignments[i] = a.copyWith(
        startSlot: newDays.first,
        duration: newDays.length,
        customDays: consec ? [] : newDays,
      );
      fixed.add('${a.course.code} (${a.classModel.shortCode}): '
          'days ${days.join(',')} normalized to ${newDays.join(',')}');
    }
    if (fixed.isNotEmpty) {
      notifyListeners();
      _saveData();
    }
    return fixed;
  }

  // ──────────────────────────────── Cross-level overlap check ────────────────────────────────
  static int _parseMin(String t) {
    final p = t.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  static bool _slotsOverlap(TimeSlot a, TimeSlot b) {
    final aS = _parseMin(a.startTime), aE = _parseMin(a.endTime);
    final bS = _parseMin(b.startTime), bE = _parseMin(b.endTime);
    return aS < bE && bS < aE;
  }

  bool isFridayBlockedSlot(TimeSlot slot, int daySlot) =>
      _fridayShortDay && daySlot == 5 && slot.period > _fridayMaxPeriod;

  bool isTeacherBusyInSlot(
      String teacherId, TimeSlot candidateSlot, int daySlot) {
    if (isFridayBlockedSlot(candidateSlot, daySlot)) return true;
    for (final a in _assignments) {
      if (a.teacher.id != teacherId) continue;
      if (!a.occupiedSlots.contains(daySlot)) continue;
      if (a.timeSlotId == candidateSlot.id) return true;
      final existing =
          _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      if (existing != null && _slotsOverlap(candidateSlot, existing)) { return true; }
    }
    return false;
  }

  static int _uidCounter = 0;
  String _uid() {
    _uidCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}_$_uidCounter';
  }

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];


  bool _areDaysFreeInSlot(List<int> days, TimeSlot candidate, String teacherId,
      String classId, String? roomId, String? excludeId,
      {String? excludeId2}) {
    // Deleted rooms leave stale roomId references on old assignments/electives
    // — ignore those as a blocker, matching countClashes()'s validRoomIds guard.
    final checkRoom =
        roomId != null && _rooms.any((r) => r.id == roomId);
    for (final eg in _electiveGroups) {
      final egSlot = _timeSlots.where((t) => t.id == eg.timeSlotId).firstOrNull;
      if (egSlot == null || !_slotsOverlap(candidate, egSlot)) continue;
      // Electives only occupy their first N days — later days are free.
      if (!days.any(electiveOccupiedDays(eg).contains)) continue;
      if (eg.classIds.contains(classId)) return false;
      if (eg.entries.any((e) => e.teacherId == teacherId)) return false;
      if (checkRoom && eg.entries.any((e) => e.roomId == roomId)) return false;
    }
    for (final day in days) {
      if (isFridayBlockedSlot(candidate, day)) return false;
      for (final a in _assignments) {
        if (a.id == excludeId || a.id == excludeId2) continue;
        if (!a.occupiedSlots.contains(day)) continue;
        bool ov = a.timeSlotId == candidate.id;
        if (!ov) {
          final ex = _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
          if (ex != null) ov = _slotsOverlap(candidate, ex);
        }
        if (!ov) continue;
        // Guard: assignments with no teacher never create a teacher clash.
        if (a.teacher.id.isNotEmpty && a.teacher.id == teacherId) { return false; }
        if (a.classModel.id == classId) { return false; }
        if (checkRoom && a.hasRoom && a.roomId == roomId) { return false; }
      }
    }
    return true;
  }

  ({List<int> days, TimeSlot slot})? _findFreeDayAndSlot(Assignment loser,
      {String? excludeAssignmentId, int maxDay = 6}) {
    final dur = loser.occupiedSlots.length.clamp(1, maxDay);
    final level = loser.classModel.level;
    final teacherId = loser.teacher.id;
    final classId = loser.classModel.id;
    final roomId = loser.roomId;

    // Keep Bachelors classes within their assigned shift (see _findFreeSlotFor).
    final shiftAllowed = effectiveAllowedSlotsForClass(classId, maxDay);
    final sameLevel = _timeSlots
        .where((t) => t.level == level)
        .where((t) => shiftAllowed == null || shiftAllowed.contains(t.id))
        .toList();

    // `maxDay - dur + 1`: the old `<= maxDay - dur` bound skipped the last
    // valid start AND never ran at all for full-week courses (dur == maxDay),
    // which made whole-course relocation of daily Inter courses impossible.
    // Start order prefers week-edge anchored blocks (college tiling pattern):
    // start-of-week first, end-of-week second, mid-week floats last.
    final lastStart = maxDay - dur + 1;
    final starts = [
      1,
      if (lastStart > 1) lastStart,
      for (int s = 2; s < lastStart; s++) s,
    ];
    for (final start in starts) {
      final block = List.generate(dur, (i) => start + i);
      for (final slot in sameLevel) {
        if (_areDaysFreeInSlot(
            block, slot, teacherId, classId, roomId, excludeAssignmentId)) {
          return (days: block, slot: slot);
        }
      }
    }
    return null;
  }

  /// Moves a single assignment to a different period, keeping its days,
  /// teacher, room and credit hours exactly as they are — a pure card
  /// relocation, nothing else changes. Returns null on success, or a
  /// message explaining why the move was rejected.
  String? moveAssignmentPeriod(String assignmentId, String newTimeSlotId,
      {int workingDays = 6}) {
    final i = _assignments.indexWhere((a) => a.id == assignmentId);
    if (i == -1) return 'Assignment not found — the data may have changed.';
    final a = _assignments[i];
    if (!a.autoAssigned) {
      return '"${a.course.code}" (${a.classModel.shortCode}) is a manual allocation — locked, not moved.';
    }
    if (_lockedSlotIdFor(a) != null) {
      return '"${a.course.code}" (${a.classModel.shortCode}) is time-slot-locked — remove the lock first.';
    }
    final newSlot = _timeSlots.where((t) => t.id == newTimeSlotId).firstOrNull;
    if (newSlot == null) return 'Target period not found.';
    if (newSlot.level != a.classModel.level) {
      return 'That period belongs to a different education level.';
    }
    final shiftAllowed =
        effectiveAllowedSlotsForClass(a.classModel.id, workingDays);
    if (shiftAllowed != null && !shiftAllowed.contains(newTimeSlotId)) {
      return '"${a.classModel.shortCode}" isn\'t allowed in that period (shift restriction).';
    }
    if (!_areDaysFreeInSlot(a.occupiedSlots, newSlot, a.teacher.id,
        a.classModel.id, a.roomId, a.id)) {
      return 'That period isn\'t free — it clashes with an existing '
          'assignment or elective on the same days.';
    }
    _assignments[i] = a.copyWith(id: _uid(), timeSlotId: newTimeSlotId);
    notifyListeners();
    _saveData();
    return null;
  }

  void _evictElectiveSlotConflicts() {
    if (_electiveGroups.isEmpty) return;
    bool changed = false;
    bool found = true;
    while (found) {
      found = false;
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        final inElective = _electiveGroups.any((eg) =>
            eg.classIds.contains(a.classModel.id) &&
            eg.timeSlotId == a.timeSlotId &&
            // Only the elective's own days conflict — leftover days are free.
            a.occupiedSlots.any(electiveOccupiedDays(eg).contains));
        if (!inElective) continue;
        final free = _findFreeDayAndSlot(a, excludeAssignmentId: a.id);
        if (free == null) {
          // Nowhere free: KEEP the assignment. Silently deleting user data is
          // worse than a visible clash — Fix Now / Health Check will surface it.
          debugPrint('evict: no free slot for ${a.course.code} '
              '(${a.classModel.shortCode}) — left in elective slot ${a.timeSlotId}');
          continue;
        }
        _assignments[i] = a.copyWith(
          id: _uid(),
          timeSlotId: free.slot.id,
          startSlot: free.days.first,
          duration: a.duration, // preserve original credit hours
          customDays: free.days,
        );
        changed = true;
        found = true;
        break;
      }
    }
    if (changed) {
      notifyListeners();
      _saveData();
    }
  }

  /// Re-join courses that earlier clash-fixes split across two periods
  /// (same course+class+teacher in >1 record). The merged course gets one
  /// contiguous day block in a single period — its own period if there is
  /// room, otherwise any free one. Groups with no single-period home are
  /// left split and reported.
  List<String> mergeSplitCourses({int workingDays = 6}) {
    final messages = <String>[];
    final groups = <String, List<Assignment>>{};
    for (final a in _assignments) {
      // Room is part of the key so pieces are only merged when they truly
      // belong together — merging across rooms would silently drop
      // whichever room the smaller piece was placed in.
      final key =
          '${a.course.code.trim().toUpperCase()}|${a.classModel.id}|${a.teacher.id}|${a.roomId ?? ''}';
      groups.putIfAbsent(key, () => []).add(a);
    }
    bool changed = false;
    for (final pieces in groups.values.where((g) => g.length > 1)) {
      // ── GUARD: never merge pieces if ANY piece is pinned (manual).
      // Pinned assignments are sacred — the user placed them deliberately.
      // Merging could move them to a different period, which is prohibited.
      if (pieces.any((p) => !p.autoAssigned)) {
        continue; // leave pinned pieces exactly where they are
      }

      final rawTotal = pieces
          .expand((p) => p.occupiedSlots)
          .toSet()
          .length
          .clamp(1, workingDays);
      // Use the course's creditHours as the floor — if pieces were partially
      // lost we must still allocate the full course duration.
      final totalDays = rawTotal < pieces.first.course.creditHours
          ? pieces.first.course.creditHours.clamp(1, workingDays)
          : rawTotal;
      final biggest = pieces.reduce(
          (a, b) => b.occupiedSlots.length > a.occupiedSlots.length ? b : a);
      // Remove the pieces first so the free-search doesn't count them as busy;
      // restored below if no merged home exists.
      _assignments.removeWhere((a) => pieces.any((p) => p.id == a.id));

      List<int>? days;
      TimeSlot? slot;
      // ONLY try the biggest piece's own period — NEVER move to a different period.
      // Moving to a random period is what caused Pak Studies to jump from slot 6 to slot 2.
      final ownSlot =
          _timeSlots.where((t) => t.id == biggest.timeSlotId).firstOrNull;
      if (ownSlot != null) {
        for (int start = 1;
            start <= workingDays - totalDays + 1 && days == null;
            start++) {
          final block = List.generate(totalDays, (i) => start + i);
          if (_areDaysFreeInSlot(block, ownSlot, biggest.teacher.id,
              biggest.classModel.id, biggest.roomId, null)) {
            days = block;
            slot = ownSlot;
          }
        }
      }
      if (days != null && slot != null) {
        _assignments.add(biggest.copyWith(
          id: _uid(),
          timeSlotId: slot.id,
          startSlot: days.first,
          duration: days.length,
          customDays: const [],
        ));
        messages.add(
            'Merged "${biggest.course.code}" (${biggest.classModel.shortCode}) '
            'into one block: ${_dayNames[days.first - 1]}-${_dayNames[days.last - 1]} '
            '@ ${slot.shortLabel}');
        changed = true;
      } else {
        // Could not merge in original period — restore pieces exactly where they were.
        _assignments.addAll(pieces);
        messages.add(
            'Could not merge "${biggest.course.code}" (${biggest.classModel.shortCode}) '
            '-- original period has no $totalDays free days. Left in place.');
      }
    }
    if (changed) {
      notifyListeners();
      _saveData();
    }
    return messages;
  }

  /// Read-only clash count for the dashboard badge (see dashboard_screen.dart).
  /// Independent port of matrix_screen.dart's own verified clash scan —
  /// deliberately NOT shared code, so nothing here can regress that proven
  /// clash-free view; this only needs a count, not the per-id highlight sets
  /// matrix_screen also produces.
  int countClashes() {
    final aList = combinedAssignments;
    final slotBounds = {
      for (final t in _timeSlots) t.id: (s: _parseMin(t.startTime), e: _parseMin(t.endTime))
    };
    bool slotsOverlap(String idA, String idB) {
      if (idA == idB) return true;
      final a = slotBounds[idA];
      final b = slotBounds[idB];
      if (a == null || b == null) return false;
      return a.s < b.e && b.s < a.e;
    }

    final Map<String, List<Assignment>> byTs = {};
    for (final a in aList) { byTs.putIfAbsent(a.timeSlotId, () => []).add(a); }
    final tsIds = byTs.keys.toList();

    final Map<String, List<ElectiveGroup>> egByOverlappingTs = {
      for (final tsId in tsIds)
        tsId: _electiveGroups.where((eg) => slotsOverlap(eg.timeSlotId, tsId)).toList(),
    };
    final Map<String, String?> egIdCache = {
      for (final a in aList)
        a.id: a.id.startsWith('elec_')
            ? egByOverlappingTs[a.timeSlotId]
                ?.where((eg) => eg.classIds.contains(a.classModel.id))
                .map((eg) => eg.id)
                .firstOrNull
            : null,
    };
    final validRoomIds = {for (final r in _rooms) r.id};

    var clashCount = 0;
    void checkPair(Assignment a, Assignment b) {
      final shared = a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
      if (shared.isEmpty) return;
      if (a.course.id == b.course.id) {
        final isCombined = _combinedRules.any((r) =>
            r.courseId == a.course.id &&
            r.classIds.contains(a.classModel.id) &&
            r.classIds.contains(b.classModel.id));
        if (isCombined) return;
      }
      final aEgId = egIdCache[a.id];
      final bEgId = egIdCache[b.id];
      if (aEgId != null && aEgId == bEgId) return;

      if ((a.teacher.id.isNotEmpty && a.teacher.id == b.teacher.id) ||
          a.classModel.id == b.classModel.id ||
          (a.hasRoom && b.hasRoom && a.roomId == b.roomId && validRoomIds.contains(a.roomId))) {
        clashCount++;
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
    return clashCount;
  }

  /// Detects and auto-fixes ALL scheduling clashes by MOVING the clashing
  /// days to a free time slot when possible.
  ///
  ///  1. TEACHER clashes: same teacher double-booked at overlapping clock times.
  ///  2. CLASS clashes:   same class has two courses at overlapping times.
  ///
  /// Priority: Bachelors > Intermediate; within same level more days wins.
  /// The slot a Time Slot Lock binds [a] to, or null if unlocked. Same
  /// matching as the GA's lockedSlots (courseId + level + optional classId).
  String? _lockedSlotIdFor(Assignment a) {
    for (final l in _timeSlotLocks) {
      if (l.courseId == a.course.id &&
          l.level == a.classModel.level &&
          (l.classId == null ||
              l.classId!.isEmpty ||
              l.classId == a.classModel.id)) {
        return l.timeSlotId;
      }
    }
    return null;
  }

  Future<List<String>> fixTeacherClashes({int workingDays = 6}) async {
    final messages = <String>[];
    _isFixing = true;
    try {
    // Pass -1: re-join previously split courses before clash-fixing — fewer,
    // whole records for the fixer to place, and the split damage is undone.
    messages.addAll(mergeSplitCourses(workingDays: workingDays));

    // Pass -1b: Out-of-bounds repair check.
    // If an assignment was pushed beyond the end of the week, shift it back
    // so it fits. NEVER alter duration — the user may have overridden it intentionally!
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      if (!a.autoAssigned) continue;
      if (a.customDays.isNotEmpty) continue;
      
      final outOfBounds = a.startSlot + a.duration - 1 > workingDays;
      if (!outOfBounds) continue;
      
      final safeStart = (workingDays - a.duration + 1).clamp(1, workingDays);
      _assignments[i] = a.copyWith(startSlot: safeStart, customDays: []);
      messages.add('[Bounds Repair] "${a.course.code}" (${a.classModel.shortCode}) '
          'shifted from Day ${a.startSlot} to Day $safeStart to fit in the week.');
    }

    bool foundClash = true;

    bool overlaps(String idA, String idB, TimeSlot? slotA, TimeSlot? slotB) {
      if (idA == idB) return true;
      if (slotA == null || slotB == null) return false;
      return _slotsOverlap(slotA, slotB);
    }

    bool isCombinedMatch(Assignment a, Assignment b) {
      if (a.course.id != b.course.id) return false;
      for (final rule in _combinedRules) {
        if (rule.courseId == a.course.id &&
            rule.classIds.contains(a.classModel.id) &&
            rule.classIds.contains(b.classModel.id)) {
          return true;
        }
      }
      return false;
    }

    /// Move [loser] entirely to a clash-free slot+days, or trim as last resort.
    /// Returns whether the assignment was actually changed (moved/trimmed) —
    /// false means it was left in place because nowhere free could be found,
    /// which the caller must NOT treat as "made progress" (see the outer
    /// while-loop: retrying an unchanged pair forever would starve every
    /// other clash in the schedule from ever being reached).
    bool resolveClash(
        int loserIdx, Set<int> shared, String winnerCode, String label) {
      final loser = _assignments[loserIdx];
      // Manual allocations are fixed — Fix Now must never move or trim them.
      if (!loser.autoAssigned) {
        messages.add(
            '[$label] "${loser.course.code}" (${loser.classModel.shortCode}) '
            'is a manual allocation — locked, not moved.');
        return false;
      }
      final clashDays = shared.toList()..sort();
      final dayStr = clashDays.map((d) => _dayNames[d - 1]).join(', ');

      // ═══════════════════════════════════════════════════════════════════════
      // CRITICAL RULE: NEVER split a course into smaller pieces.
      // All strategies move the WHOLE assignment as one block, preserving
      // its original duration. A 6cr English stays 6cr. A 5cr Urdu stays 5cr.
      // ═══════════════════════════════════════════════════════════════════════
      final origDuration = loser.duration; // sacred — never change this

      // Time Slot Lock awareness: a lock-bound course must STAY in its locked
      // period — Fix Now may only re-arrange its days there (Strategy 0),
      // never relocate it. Without this, Fix Now "resolved" clashes by
      // silently moving locked courses out of the very slot the user locked.
      final lockedTs = _lockedSlotIdFor(loser);

      // Strategy 0: Day Slide — shift start day within the SAME period.
      // Cheapest fix: no period change, just different days to avoid the clash.
      {
        final loserSlot = _timeSlots.where((t) => t.id == loser.timeSlotId).firstOrNull;
        if (loserSlot != null) {
          for (int sd = 1; sd <= workingDays - origDuration + 1; sd++) {
            final newDays = List.generate(origDuration, (i) => sd + i);
            // Skip if identical to current position
            if (sd == loser.startSlot && loser.customDays.isEmpty) continue;
            // New days must NOT overlap with the clash days
            if (newDays.toSet().intersection(shared).isNotEmpty) continue;
            // Must be free of ALL other conflicts (teacher, class, room)
            if (_areDaysFreeInSlot(newDays, loserSlot, loser.teacher.id,
                loser.classModel.id, loser.roomId, loser.id)) {
              _assignments[loserIdx] = loser.copyWith(
                id: _uid(),
                startSlot: sd,
                duration: origDuration,
                customDays: [],
              );
              messages.add(
                  '[$label] Slid "${loser.course.code}" (${loser.classModel.shortCode}) '
                  'to ${_dayNames[sd - 1]}–${_dayNames[sd + origDuration - 2]} '
                  'in same period (avoiding $dayStr)');
              return true;
            }
          }
        }
      }

      // Strategy 1: Move the WHOLE assignment to a different period (same days).
      // Look for another time slot where the teacher+class+room are all free
      // on ALL of the loser's current days.
      {
        final loserDays = loser.occupiedSlots.toList()..sort();
        final shiftAllowed = effectiveAllowedSlotsForClass(
            loser.classModel.id, workingDays);
        for (final candidate in _timeSlots.where((t) =>
            t.level == loser.classModel.level &&
            t.id != loser.timeSlotId &&
            (lockedTs == null || t.id == lockedTs) &&
            (shiftAllowed == null || shiftAllowed.contains(t.id)))) {
          if (_areDaysFreeInSlot(loserDays, candidate, loser.teacher.id,
              loser.classModel.id, loser.roomId, loser.id)) {
            _assignments[loserIdx] = loser.copyWith(
              id: _uid(),
              timeSlotId: candidate.id,
              startSlot: loserDays.first,
              duration: origDuration,
              customDays: loserDays.length == origDuration &&
                      loserDays.last - loserDays.first + 1 == origDuration
                  ? []
                  : loserDays,
            );
            messages.add(
                '[$label] Moved "${loser.course.code}" (${loser.classModel.shortCode}) '
                'to period ${candidate.shortLabel} (same days, was clashing '
                'with "$winnerCode" on $dayStr)');
            return true;
          }
        }
      }

      // Strategy 2: Relocate the WHOLE assignment to a completely free
      // day-block + period. Uses the original duration to find a contiguous
      // block of exactly `origDuration` free days.
      final free2 = _findFreeDayAndSlot(loser, excludeAssignmentId: loser.id, maxDay: workingDays);
      if (free2 != null && (lockedTs == null || free2.slot.id == lockedTs)) {
        _assignments[loserIdx] = loser.copyWith(
          id: _uid(),
          timeSlotId: free2.slot.id,
          startSlot: free2.days.first,
          duration: origDuration,
          customDays:
              free2.days.length == free2.days.last - free2.days.first + 1
                  ? []
                  : free2.days,
        );
        messages.add(
            '[$label] Relocated "${loser.course.code}" (${loser.classModel.shortCode}) '
            'to days ${free2.days.map((d) => _dayNames[d - 1]).join(',')} @ ${free2.slot.shortLabel} '
            '(was clashing with "$winnerCode" on $dayStr)');
        return true;
      }

      // Strategy 3: Pairwise Swap — exchange periods with a compatible
      // non-clashing assignment. Works when the schedule is dense and no
      // empty space exists, but two assignments can trade places safely.
      {
        final loserDays = loser.occupiedSlots.toList()..sort();
        final loserSlot = _timeSlots.where((t) => t.id == loser.timeSlotId).firstOrNull;
        if (loserSlot != null) {
          for (int xi = 0; xi < _assignments.length; xi++) {
            if (xi == loserIdx) continue;
            final x = _assignments[xi];
            if (!x.autoAssigned) continue;          // never swap with pinned
            if (x.classModel.level != loser.classModel.level) continue;
            if (x.timeSlotId == loser.timeSlotId) continue; // same period won't help
            // Lock guards: loser may only land in its locked period, and the
            // partner must not be pulled out of its own locked period.
            if (lockedTs != null && x.timeSlotId != lockedTs) continue;
            final xLock = _lockedSlotIdFor(x);
            if (xLock != null && xLock != loser.timeSlotId) continue;
            final xSlot = _timeSlots.where((t) => t.id == x.timeSlotId).firstOrNull;
            if (xSlot == null) continue;
            // Check shift constraints (morning/evening for bachelors)
            final loserShiftAllowed = effectiveAllowedSlotsForClass(loser.classModel.id, workingDays);
            if (loserShiftAllowed != null && !loserShiftAllowed.contains(x.timeSlotId)) continue;
            
            final xShiftAllowed = effectiveAllowedSlotsForClass(x.classModel.id, workingDays);
            if (xShiftAllowed != null && !xShiftAllowed.contains(loser.timeSlotId)) continue;

            final xDays = x.occupiedSlots.toList()..sort();

            // Check: can loser fit in X's period+days?
            final loserFitsInX = _areDaysFreeInSlot(
                loserDays, xSlot, loser.teacher.id, loser.classModel.id,
                loser.roomId, loser.id, excludeId2: x.id);
            if (!loserFitsInX) continue;

            // Check: can X fit in loser's period+days?
            final xFitsInLoser = _areDaysFreeInSlot(
                xDays, loserSlot, x.teacher.id, x.classModel.id,
                x.roomId, x.id, excludeId2: loser.id);
            if (!xFitsInLoser) continue;

            // Swap periods — preserve everything else (duration, days, room)
            _assignments[loserIdx] = loser.copyWith(
              id: _uid(),
              timeSlotId: x.timeSlotId,
            );
            _assignments[xi] = x.copyWith(
              id: _uid(),
              timeSlotId: loser.timeSlotId,
            );
            messages.add(
                '[$label] Swapped "${loser.course.code}" (${loser.classModel.shortCode}) '
                '↔ "${x.course.code}" (${x.classModel.shortCode}) periods '
                '(resolving clash with "$winnerCode" on $dayStr)');
            return true;
          }
        }
      }

      // ponytail: Strategies 4 (Cascade Chain Move), 5 (Exhaustive day-shift,
      // fully redundant with Strategy 2's _findFreeDayAndSlot search space)
      // and 6 (N-Way Cyclic Swap) were removed 2026-08-13 — they only ever
      // ran after S0-S3 already failed, and were the dominant cost on
      // structurally-stuck clashes (S4/S6 each call countClashes(), an O(n)
      // full rescan, inside nested loops). If a future case needs them, they
      // covered: moving a third blocking course out of the way first (S4),
      // and 3-way slot cycling when no direct swap partner exists (S6).

      messages.add(lockedTs != null
          ? '[$label] "${loser.course.code}" (${loser.classModel.shortCode}) is '
              'lock-bound to its time slot and no clash-free days exist there — '
              'still clashing with "$winnerCode" on $dayStr. Remove the lock '
              'for this class or free up that period.'
          : '[$label] Could not relocate "${loser.course.code}" (${loser.classModel.shortCode}) '
              '-- no free slot found; still clashing with "$winnerCode" on $dayStr. '
              'Resolve manually via Transfers & Swap or use the Pinned Conflicts '
              'panel in the GA Report to unpin one of the pair.');
      return false;
    }


    // ── Pass 0: evict any regular assignment that clock-overlaps an elective ──
    // group it clashes with (same class, or same teacher/room across classes).
    // Elective groups are fixed once created — regular courses must move instead.
    bool evictedAny = true;
    while (evictedAny) {
      evictedAny = false;
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        final aSlot = _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
        if (aSlot == null) continue;
        final inElective = _electiveGroups.where((eg) {
          final egSlot = _timeSlots.where((t) => t.id == eg.timeSlotId).firstOrNull;
          if (egSlot == null || !_slotsOverlap(aSlot, egSlot)) return false;
          // Leftover days of the elective period are free — no conflict.
          if (!a.occupiedSlots.any(electiveOccupiedDays(eg).contains)) return false;
          if (eg.classIds.contains(a.classModel.id)) return true;
          if (eg.entries.any((e) => e.teacherId == a.teacher.id)) return true;
          if (a.hasRoom && eg.entries.any((e) => e.roomId == a.roomId)) return true;
          return false;
        }).firstOrNull;
        if (inElective == null) continue;
        if (!a.autoAssigned) {
          // Manual allocations are fixed — report the elective conflict only.
          messages.add(
              '[Elective] "${a.course.code}" (${a.classModel.shortCode}) overlaps '
              'an elective slot but is a manual allocation — locked, not moved.');
          continue;
        }
        // Move all days of this assignment out of the elective slot
        final free = _findFreeDayAndSlot(a, excludeAssignmentId: a.id, maxDay: workingDays);
        if (free != null) {
          _assignments[i] = a.copyWith(
            id: _uid(),
            timeSlotId: free.slot.id,
            startSlot: free.days.first,
            duration: a.duration, // preserve original credit hours
            customDays: free.days,
          );
          messages.add(
              '[Elective] Moved "${a.course.code}" (${a.classModel.shortCode}) '
              'out of elective slot → ${free.slot.id}');
        } else {
          // Nowhere free: KEEP it — a visible clash beats silent deletion.
          messages.add(
              '[Elective] "${a.course.code}" (${a.classModel.shortCode}) clashes '
              'with an elective slot and nowhere is free — left in place, '
              'resolve manually.');
          continue;
        }
        evictedAny = true;
        break;
      }
    }

    int iterations = 0;
    // Pairs whose FULL strategy ladder already failed this run. Every later
    // iteration re-scans all pairs, so without this each stuck pair re-ran
    // the exhaustive S0–S6 ladder once per successful fix elsewhere — the
    // bulk of Fix Now's freeze on schedules with unresolvable clashes.
    // ponytail: kept for the whole run (a stuck pair COULD become fixable
    // after another move); the next Fix Now click retries everything.
    final unresolvable = <String>{};
    final slotById = {for (final t in _timeSlots) t.id: t};
    // Deleted rooms leave stale roomId references on old assignments —
    // ignore those as a "room clash" signal, matching countClashes().
    final validRoomIds = {for (final r in _rooms) r.id};
    while (foundClash && iterations < 200) {
      iterations++;
      foundClash = false;
      // Yield so the UI thread paints (spinner, window events) between passes.
      await Future.delayed(Duration.zero);
      outer:
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        final slotA = slotById[a.timeSlotId];

        for (int j = i + 1; j < _assignments.length; j++) {
          final b = _assignments[j];
          final slotB = slotById[b.timeSlotId];

          if (!overlaps(a.timeSlotId, b.timeSlotId, slotA, slotB)) continue;

          final shared =
              a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
          if (shared.isEmpty) continue;

          // Legitimate combined classes are SUPPOSED to overlap (same teacher, slot, room).
          if (isCombinedMatch(a, b)) continue;

          // Ã¢â€â‚¬Ã¢â€â‚¬ TEACHER CLASH Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
          if (a.teacher.id.isNotEmpty && a.teacher.id == b.teacher.id) {
            final pk = '${a.id}|${b.id}';
            if (unresolvable.contains(pk)) continue;
            final aIsBach = a.classModel.level == EducationLevel.bachelors;
            final bIsBach = b.classModel.level == EducationLevel.bachelors;
            // Pinned (manual) assignments are immovable — always treat them as
            // the "winner" so Fix Now tries to move the auto-assigned one first.
            final keepA = (!a.autoAssigned && b.autoAssigned)
                ? true
                : (!b.autoAssigned && a.autoAssigned)
                    ? false
                    : (aIsBach && !bIsBach) ||
                        (aIsBach == bIsBach &&
                            a.occupiedSlots.length >= b.occupiedSlots.length);
            var resolved = resolveClash(keepA ? j : i, shared, (keepA ? a : b).course.code,
                'Teacher: ${a.teacher.name}');
            // Preferred loser stuck or pinned? Try moving the other card.
            resolved = resolved ||
                resolveClash(keepA ? i : j, shared, (keepA ? b : a).course.code,
                    'Teacher: ${a.teacher.name}');
            if (!resolved && !a.autoAssigned && !b.autoAssigned) {
              // Both are pinned — truly unavoidable without user action.
              messages.add(
                  '[Teacher: ${a.teacher.name}] Both "${a.course.code}" '
                  '(${a.classModel.shortCode}) and "${b.course.code}" '
                  '(${b.classModel.shortCode}) are manually pinned to the same '
                  'slot — unpin one, or add them as a Combined Class rule.');
            }
            if (resolved) {
              foundClash = true;
              // The schedule just changed — any pair marked unresolvable
              // earlier in this run deserves a retry, since the ladder is
              // cheap now (S0-S3 only, no countClashes() calls left in it).
              unresolvable.clear();
              break outer;
            }
            unresolvable.add(pk);
            continue;
          }

          // Ã¢â€â‚¬Ã¢â€â‚¬ CLASS CLASH Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
          if (a.classModel.id == b.classModel.id) {
            final pk = '${a.id}|${b.id}';
            if (unresolvable.contains(pk)) continue;
            final combinedCourseIds =
                _combinedRules.map((r) => r.courseId).toSet();
            final aIsCombined = combinedCourseIds.contains(a.course.id);
            final bIsCombined = combinedCourseIds.contains(b.course.id);
            // Pinned > combined > day-count for winner priority.
            final keepA = (!a.autoAssigned && b.autoAssigned)
                ? true
                : (!b.autoAssigned && a.autoAssigned)
                    ? false
                    : aIsCombined
                        ? true
                        : bIsCombined
                            ? false
                            : a.occupiedSlots.length >= b.occupiedSlots.length;
            var resolved = resolveClash(keepA ? j : i, shared, (keepA ? a : b).course.code,
                'Class: ${a.classModel.shortCode}');
            // Fallback: move the other card — unless it's combined-protected.
            if (!resolved && !(keepA ? aIsCombined : bIsCombined)) {
              resolved = resolveClash(keepA ? i : j, shared, (keepA ? b : a).course.code,
                  'Class: ${a.classModel.shortCode}');
            }
            if (!resolved && !a.autoAssigned && !b.autoAssigned) {
              messages.add(
                  '[Class: ${a.classModel.shortCode}] Both "${a.course.code}" '
                  'and "${b.course.code}" are manually pinned to the same slot '
                  '— unpin one to allow auto-resolution.');
            }
            if (resolved) {
              foundClash = true;
              // The schedule just changed — any pair marked unresolvable
              // earlier in this run deserves a retry, since the ladder is
              // cheap now (S0-S3 only, no countClashes() calls left in it).
              unresolvable.clear();
              break outer;
            }
            unresolvable.add(pk);
            continue;
          }

          // Ã¢â€â‚¬Ã¢â€â‚¬ ROOM CLASH Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
          if (a.hasRoom &&
              b.hasRoom &&
              a.roomId == b.roomId &&
              validRoomIds.contains(a.roomId)) {
            if (isCombinedMatch(a, b)) continue;
            final pk = '${a.id}|${b.id}';
            if (unresolvable.contains(pk)) continue;
            // Pinned assignments win for room clashes too.
            final keepA = (!a.autoAssigned && b.autoAssigned)
                ? true
                : (!b.autoAssigned && a.autoAssigned)
                    ? false
                    : a.occupiedSlots.length >= b.occupiedSlots.length;
            var resolved = resolveClash(keepA ? j : i, shared, (keepA ? a : b).course.code,
                'Room: ${a.roomId}');
            resolved = resolved ||
                resolveClash(keepA ? i : j, shared, (keepA ? b : a).course.code,
                    'Room: ${a.roomId}');
            if (!resolved && !a.autoAssigned && !b.autoAssigned) {
              messages.add(
                  '[Room: ${a.roomId}] Both "${a.course.code}" '
                  '(${a.classModel.shortCode}) and "${b.course.code}" '
                  '(${b.classModel.shortCode}) are manually pinned to the same '
                  'room and slot — unpin one to allow auto-resolution.');
            }
            if (resolved) {
              foundClash = true;
              // The schedule just changed — any pair marked unresolvable
              // earlier in this run deserves a retry, since the ladder is
              // cheap now (S0-S3 only, no countClashes() calls left in it).
              unresolvable.clear();
              break outer;
            }
            unresolvable.add(pk);
            continue;
          }
        }
      }
    }

    // ── Smart Day Spread ────────────────────────────────────────────────────────
    // Resolves teacher clashes where the teacher has multiple assignments at the
    // SAME clock time but currently overlapping on the same days.
    // Strategy: redistribute start days within the same clock window so every
    // assignment gets a non-overlapping day block.
    // KEY FIX: group by CLOCK TIME (startMin+endMin), not by slot ID — two
    // assignments may have different slot IDs but the same clock time (e.g.
    // "inter_p1" vs "ics_p1" both at 08:00-08:40) and must be treated as the
    // same period for day-spread purposes.
    {
      // Precompute clock intervals for all slots
      final Map<String, ({int s, int e})> clockOf = {
        for (final t in _timeSlots)
          t.id: (s: _parseMin(t.startTime), e: _parseMin(t.endTime))
      };

      // Build (teacher, clockKey) → list of assignment indices
      // clockKey = "startMin_endMin" to group by real clock overlap, not slot ID
      final Map<String, List<int>> teacherClockGroups = {};
      for (int i = 0; i < _assignments.length; i++) {
        final a = _assignments[i];
        if (a.teacher.id.isEmpty) continue;
        final clk = clockOf[a.timeSlotId];
        // If no clock data, fall back to slot ID so we still attempt a spread
        final clockKey = (clk != null && clk.e > 0)
            ? '${clk.s}_${clk.e}'
            : a.timeSlotId;
        final key = '${a.teacher.id}|||$clockKey';
        teacherClockGroups.putIfAbsent(key, () => []).add(i);
      }

      for (final entry in teacherClockGroups.entries) {
        final group = entry.value;
        if (group.length < 2) continue;

        // Only process groups that have at least one clashing pair (day overlap)
        bool hasClash = false;
        for (int x = 0; x < group.length && !hasClash; x++) {
          final ax = _assignments[group[x]];
          for (int y = x + 1; y < group.length; y++) {
            final ay = _assignments[group[y]];
            if (isCombinedMatch(ax, ay)) continue;
            final shared = ax.occupiedSlots.toSet().intersection(ay.occupiedSlots.toSet());
            if (shared.isNotEmpty) { hasClash = true; break; }
          }
        }
        if (!hasClash) continue;

        // Skip if every clashing pair is a legitimate combined class
        bool allCombined = true;
        for (int x = 0; x < group.length; x++) {
          for (int y = x + 1; y < group.length; y++) {
            if (!isCombinedMatch(_assignments[group[x]], _assignments[group[y]])) {
              allCombined = false; break;
            }
          }
          if (!allCombined) break;
        }
        if (allCombined) continue;

        // ── GUARD 1: Only spread when the teacher teaches the SAME COURSE to
        // multiple sections. This is the intended Pak Studies pattern.
        // Groups mixing different subjects at the same clock time are left
        // untouched to avoid disrupting the broader schedule.
        final spreadCourseIds = group.map((i) => _assignments[i].course.id).toSet();
        if (spreadCourseIds.length > 1) continue;

        // ── GUARD 3: Pinned spread exception for same-course/same-teacher/
        // different-class groups (the Pak Studies pattern).
        //
        // Rule: A teacher teaches the SAME course to DIFFERENT classes, all
        // pinned to the SAME slot but accidentally placed on the SAME days.
        // Spreading their start days within the same slot is safe because:
        //   • The slot (period) never changes      → pin is respected ✓
        //   • The duration never changes            → credit hours safe ✓
        //   • Only the start day shifts within the week → minimum change ✓
        //
        // For all other pinned groups (mixed courses, same class, etc.) we
        // still skip — those require explicit user action.
        final allDifferentClasses = group
            .map((i) => _assignments[i].classModel.id)
            .toSet()
            .length == group.length;
        final allPinned = group.every((i) => !_assignments[i].autoAssigned);
        // Allow spread only when: all pinned AND all different classes.
        // If any member is auto-assigned the old rule applies (allow freely).
        // If some pinned but not all-different-classes → skip (unsafe).
        if (allPinned && !allDifferentClasses) continue;
        if (!allPinned && group.any((i) => !_assignments[i].autoAssigned)) continue;


        // Skip ONLY non-consecutive customDays (e.g. [1,3,5]).
        // Consecutive [1,2] or [3,4] are handled identically to startDay+duration.
        bool hasNonConsecutive = false;
        for (final i in group) {
          final cd = _assignments[i].customDays;
          if (cd.length > 1) {
            final sdCopy = [...cd]..sort();
            for (int k = 0; k < sdCopy.length - 1; k++) {
              if (sdCopy[k + 1] != sdCopy[k] + 1) { hasNonConsecutive = true; break; }
            }
          }
          if (hasNonConsecutive) break;
        }
        if (hasNonConsecutive) continue;

        // Total days must fit in the working week
        final totalDays = group.fold<int>(0, (s, i) => s + _assignments[i].occupiedSlots.length);
        if (totalDays > workingDays) {
          messages.add('[Smart Spread] Teacher ${_assignments[group.first].teacher.name} '
              'has ${group.length} assignments totalling $totalDays days — '
              'exceeds working week ($workingDays days). Cannot spread.');
          continue;
        }

        // Sort by first occupied day ascending
        final sorted = [...group]
          ..sort((i, j) {
            final di = _assignments[i].occupiedSlots;
            final dj = _assignments[j].occupiedSlots;
            final fi = di.isEmpty ? 99 : di.reduce((a, b) => a < b ? a : b);
            final fj = dj.isEmpty ? 99 : dj.reduce((a, b) => a < b ? a : b);
            return fi.compareTo(fj);
          });

        // Use an index-set for O(1) sibling lookup (avoids indexOf O(n) inside loop)
        final siblingIdxSet = group.toSet();

        // Greedy non-overlapping day assignment with class-level conflict check
        bool feasible = true;
        int nextDay = 1;
        final proposed = <int, ({int startDay, int dur})>{};

        for (final idx in sorted) {
          final a = _assignments[idx];
          final dur = a.occupiedSlots.length;
          bool placed = false;

          for (int sd = nextDay; sd + dur - 1 <= workingDays; sd++) {
            final newDays = List.generate(dur, (k) => sd + k);
            final slot = _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;

            // Reject days blocked by Friday rules
            if (slot != null && newDays.any((d) => isFridayBlockedSlot(slot, d))) continue;

            // Reject if class already has another subject at this slot on these days
            bool classConflict = false;
            for (int oi = 0; oi < _assignments.length; oi++) {
              final other = _assignments[oi];
              if (other.id == a.id) continue;
              if (other.classModel.id != a.classModel.id) continue;
              // Skip sibling assignments — they get their own window in proposed
              if (siblingIdxSet.contains(oi)) continue;
              // Check clock overlap with a's slot
              bool slotOv = other.timeSlotId == a.timeSlotId;
              if (!slotOv && slot != null) {
                final os = _timeSlots.where((t) => t.id == other.timeSlotId).firstOrNull;
                if (os != null) slotOv = _slotsOverlap(slot, os);
              }
              if (!slotOv) continue;
              // Day overlap?
              final otherDays = other.occupiedSlots.toSet();
              if (newDays.any(otherDays.contains) && !isCombinedMatch(a, other)) {
                classConflict = true; break;
              }
            }
            if (classConflict) continue;

            // ── GUARD 2: Reject days occupied by elective groups for this class.
            // Elective groups are NOT in _assignments (they use synthetic IDs),
            // so the loop above misses them. Check them separately.
            bool electiveConflict = false;
            for (final eg in _electiveGroups) {
              if (!eg.classIds.contains(a.classModel.id)) continue;
              final egSlot = _timeSlots.where((t) => t.id == eg.timeSlotId).firstOrNull;
              if (egSlot == null || slot == null || !_slotsOverlap(slot, egSlot)) continue;
              // Elective occupies days 1..maxCr (same as combinedAssignments/electiveOccupiedDays)
              int maxCr = 1;
              for (final e in eg.entries) {
                final cr = _courses.where((c) => c.id == e.courseId).firstOrNull?.creditHours ?? 3;
                if (cr > maxCr) maxCr = cr;
              }
              final egDays = Set<int>.from(List.generate(maxCr, (k) => k + 1));
              if (newDays.any(egDays.contains)) { electiveConflict = true; break; }
            }
            if (electiveConflict) continue;

            proposed[idx] = (startDay: sd, dur: dur);
            nextDay = sd + dur;
            placed = true;
            break;
          }
          if (!placed) { feasible = false; break; }
        }

        if (!feasible) {
          final teacher = _assignments[group.first].teacher.name;
          final slotLabel = _timeSlots
              .where((t) => t.id == _assignments[group.first].timeSlotId)
              .firstOrNull?.shortLabel ?? _assignments[group.first].timeSlotId;
          messages.add('[Smart Spread ⚠] Cannot spread teacher $teacher at $slotLabel '
              '— class schedules are too dense at those days. '
              'Unpin one Pak Studies section or add a Combined Class rule.');
          continue;
        }

        // ── SAFETY CHECK: simulate before committing ─────────────────────────
        // Apply proposed changes tentatively, measure clash delta, and REVERT
        // if the spread does not improve the count. This catches any constraint
        // (room, cross-section, etc.) that the per-position checks above may
        // not have modelled perfectly, making the spread safe by construction.
        final clashBefore = countClashes();

        final tempBackup = <int, Assignment>{};
        for (final e in proposed.entries) {
          final a = _assignments[e.key];
          final oldFirstDay = a.occupiedSlots.isEmpty ? a.startSlot
              : a.occupiedSlots.reduce((x, y) => x < y ? x : y);
          if (oldFirstDay == e.value.startDay && a.customDays.isEmpty) continue;
          tempBackup[e.key] = a;
          _assignments[e.key] = a.copyWith(
            startSlot: e.value.startDay,
            duration: a.duration,  // preserve original credit hours — NEVER alter them
            customDays: [],
          );
        }

        if (tempBackup.isEmpty) continue; // nothing would change — skip

        final clashAfter = countClashes();
        if (clashAfter >= clashBefore) {
          // Revert — spread did not help (or made things worse)
          for (final kv in tempBackup.entries) {
            _assignments[kv.key] = kv.value;
          }
          final teacher = _assignments[group.first].teacher.name;
          messages.add('[Smart Spread ⚠] Spread for $teacher would not reduce '
              'clashes ($clashBefore→$clashAfter) — reverted.');
          continue;
        }

        // Improvement confirmed — assign permanent IDs and log
        for (final kv in tempBackup.entries) {
          final a        = kv.value;              // original assignment
          final newStart = proposed[kv.key]!.startDay;
          // Use original duration (not dur) so credit hours are unchanged
          final newDays  = List.generate(a.duration, (k) => newStart + k);
          _assignments[kv.key] = _assignments[kv.key].copyWith(id: _uid());
          messages.add('[Smart Spread ✓] "${a.course.code}" (${a.classModel.shortCode}) '
              'shifted to ${newDays.map((d) => _dayNames[d - 1]).join("–")} '
              '— teacher ${a.teacher.name} now clash-free.');
          foundClash = true;
        }
      }
    }



    // ─────────────────────────────────────────────────────────────────────────
    // Pass: Recursive Backtracking (depth-limited)
    // ─────────────────────────────────────────────────────────────────────────
    // If ANY clashes remain after all the forward-pass strategies above,
    // this pass collects the still-clashing AUTO-ASSIGNED courses, temporarily
    // unassigns them, then uses a depth-first backtracking search to find a
    // combination of (slot, startDay) that leaves the schedule fully
    // clash-free.  Pinned assignments and combined-class rules are respected
    // throughout (they stay put and are checked against).
    //
    // Safety guarantees:
    //   • Only auto-assigned (never pinned) courses are moved.        ✓
    //   • origDuration = a.duration is preserved for every course.    ✓
    //   • Shift rules (morning/evening) enforced via
    //     effectiveAllowedSlotsForClass.                              ✓
    //   • Commits ONLY when countClashes() strictly decreases.        ✓
    //   • Depth cap (5) keeps runtime bounded on large schedules.     ✓
    {
      // ── Collect still-clashing auto-assigned indices ──────────────────────
      final clashingIdxs = <int>{};
      {
        final aList = combinedAssignments;
        final slotBounds = {
          for (final t in _timeSlots)
            t.id: (s: _parseMin(t.startTime), e: _parseMin(t.endTime))
        };
        bool slotsOv(String idA, String idB) {
          if (idA == idB) return true;
          final a2 = slotBounds[idA]; final b2 = slotBounds[idB];
          if (a2 == null || b2 == null) return false;
          return a2.s < b2.e && b2.s < a2.e;
        }
        for (int i = 0; i < aList.length; i++) {
          for (int j = i + 1; j < aList.length; j++) {
            final a2 = aList[i]; final b2 = aList[j];
            if (!slotsOv(a2.timeSlotId, b2.timeSlotId)) continue;
            final sh = a2.occupiedSlots.toSet().intersection(b2.occupiedSlots.toSet());
            if (sh.isEmpty) continue;
            if (isCombinedMatch(a2, b2)) continue;
            if ((a2.teacher.id.isNotEmpty && a2.teacher.id == b2.teacher.id) ||
                a2.classModel.id == b2.classModel.id ||
                (a2.hasRoom && b2.hasRoom && a2.roomId == b2.roomId)) {
              // Find actual _assignments indices (combinedAssignments may include synthetics)
              final idxA = _assignments.indexWhere((x) => x.id == a2.id);
              final idxB = _assignments.indexWhere((x) => x.id == b2.id);
              if (idxA != -1 && _assignments[idxA].autoAssigned) clashingIdxs.add(idxA);
              if (idxB != -1 && _assignments[idxB].autoAssigned) clashingIdxs.add(idxB);
            }
          }
        }
      }

      if (clashingIdxs.isNotEmpty) {
        final clashBefore7 = countClashes();
        // Sort descending by duration so larger (harder) courses are placed first
        final sorted7 = clashingIdxs.toList()
          ..sort((a2, b2) =>
              _assignments[b2].duration.compareTo(_assignments[a2].duration));

        // Save snapshot — we revert everything if backtracking fails or doesn't help
        final snapshot7 = { for (int i = 0; i < _assignments.length; i++) i: _assignments[i] };

        // Pre-build candidate (slot, startDay) lists for each clashing index
        // so we don't recompute them inside the recursion.
        final candidates7 = <int, List<({TimeSlot slot, int startDay})>>{};
        for (final idx in sorted7) {
          final a = _assignments[idx];
          final dur = a.duration;    // NEVER change this
          final shiftAllowed = effectiveAllowedSlotsForClass(a.classModel.id, workingDays);
          final placements = <({TimeSlot slot, int startDay})>[];
          for (final slot in _timeSlots.where((t) =>
              t.level == a.classModel.level &&
              (shiftAllowed == null || shiftAllowed.contains(t.id)))) {
            for (int sd = 1; sd <= workingDays - dur + 1; sd++) {
              placements.add((slot: slot, startDay: sd));
            }
          }
          // Randomise to avoid always retrying the same bad arrangement first
          placements.shuffle();
          candidates7[idx] = placements;
        }

        // Recursive backtracker — returns true when a valid assignment is found
        // for all remaining indices in [remaining], starting at position [pos].
        bool backtrack(int pos) {
          if (pos == sorted7.length) return true;   // all placed
          final idx  = sorted7[pos];
          final orig = snapshot7[idx]!;             // original assignment
          final dur  = orig.duration;               // sacred

          for (final p in (candidates7[idx] ?? [])) {
            final tryDays = List<int>.generate(dur, (k) => p.startDay + k);
            // Temporarily remove this course from _assignments so its own
            // slot doesn't falsely block itself in _areDaysFreeInSlot
            _assignments[idx] = orig.copyWith(
              id: '__bt_removed__',
              timeSlotId: '__none__',
              startSlot: 1,
              duration: dur,
              customDays: [],
            );
            final fits = _areDaysFreeInSlot(
                tryDays, p.slot, orig.teacher.id,
                orig.classModel.id, orig.roomId, '__bt_removed__');
            if (!fits) {
              // Restore and try next
              _assignments[idx] = orig;
              continue;
            }
            // Place it tentatively
            _assignments[idx] = orig.copyWith(
              id: _uid(),
              timeSlotId: p.slot.id,
              startSlot: p.startDay,
              duration: dur,
              customDays: tryDays.last - tryDays.first + 1 == dur ? <int>[] : tryDays,
            );
            if (backtrack(pos + 1)) return true;
            // This placement led to a dead-end further down — revert
            _assignments[idx] = orig;
          }
          return false;   // no valid placement found for this course
        }

        // Depth cap: only attempt backtracking when ≤ 8 clashing courses
        // (2^8 = 256 placements max; for larger sets the cost is too high)
        if (sorted7.length <= 8) {
          final placed = backtrack(0);
          if (placed && countClashes() < clashBefore7) {
            messages.add('[Backtrack ✓] Resolved ${sorted7.length} lingering '
                'clash(es) via depth-limited backtracking.');
          } else {
            // Restore snapshot — backtracking failed or didn't help
            for (final kv in snapshot7.entries) { _assignments[kv.key] = kv.value; }
            if (!placed) {
              messages.add('[Backtrack ⚠] Could not find a valid placement for '
                  '${sorted7.length} clashing course(s) — they may be '
                  'constrained beyond what backtracking can reach. '
                  'Try adding Combined Class rules or unpinning one course.');
            }
          }
        } else {
          messages.add('[Backtrack ℹ] ${sorted7.length} courses still clashing '
              '— too many to attempt backtracking (limit 8). '
              'Run Fix Now again or unpin some courses.');
        }
      }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Pass: Phased Bachelor Course Splitting (last resort)
    // ═══════════════════════════════════════════════════════════════════════════
    // Philosophy (user-mandated):
    //   Phase 1 — already done above: try everything WITHOUT splitting.
    //   Phase 2 — if clashes remain: split BACHELOR 2cr courses into 1+1.
    //   Phase 3 — if clashes still remain: split BACHELOR 3cr courses into 2+1.
    //
    // SACRED RULES (enforced by guards below):
    //   ✗ NEVER split or alter Intermediate courses — they are sacred.
    //   ✗ NEVER split pinned (manual) assignments.
    //   ✓ Only auto-assigned Bachelor courses with duration 2 or 3 may be split.
    //   ✓ 2cr → 1+1  (two 1-day sessions in two DIFFERENT periods/days)
    //   ✓ 3cr → 2+1  (one 2-day session + one 1-day session, different periods)
    //   ✓ Total credit hours are PRESERVED:  1+1=2  /  2+1=3
    //   ✓ Each piece is auto-assigned, so mergeSplitCourses() on the NEXT
    //     Fix Now run will re-join them if space allows — no permanent damage.
    //   ✓ Shift rules (morning/evening) enforced on every piece.
    //   ✓ countClashes() must strictly decrease — full revert on failure.
    // ═══════════════════════════════════════════════════════════════════════════
    {
      // Helper: find the still-clashing auto-assigned Bachelor assignment indices.
      Set<int> stillClashingBachIdx() {
        final result = <int>{};
        final aList = combinedAssignments;
        final slotBounds = {
          for (final t in _timeSlots)
            t.id: (s: _parseMin(t.startTime), e: _parseMin(t.endTime))
        };
        bool sOv(String idA, String idB) {
          if (idA == idB) return true;
          final a2 = slotBounds[idA]; final b2 = slotBounds[idB];
          if (a2 == null || b2 == null) return false;
          return a2.s < b2.e && b2.s < a2.e;
        }
        for (int i = 0; i < aList.length; i++) {
          for (int j = i + 1; j < aList.length; j++) {
            final a2 = aList[i]; final b2 = aList[j];
            if (!sOv(a2.timeSlotId, b2.timeSlotId)) continue;
            final sh = a2.occupiedSlots.toSet().intersection(b2.occupiedSlots.toSet());
            if (sh.isEmpty) continue;
            if (isCombinedMatch(a2, b2)) continue;
            if ((a2.teacher.id.isNotEmpty && a2.teacher.id == b2.teacher.id) ||
                a2.classModel.id == b2.classModel.id ||
                (a2.hasRoom && b2.hasRoom && a2.roomId == b2.roomId)) {
              final idxA = _assignments.indexWhere((x) => x.id == a2.id);
              final idxB = _assignments.indexWhere((x) => x.id == b2.id);
              if (idxA != -1 && _assignments[idxA].autoAssigned &&
                  _assignments[idxA].classModel.level == EducationLevel.bachelors) {
                result.add(idxA);
              }
              if (idxB != -1 && _assignments[idxB].autoAssigned &&
                  _assignments[idxB].classModel.level == EducationLevel.bachelors) {
                result.add(idxB);
              }
            }
          }
        }
        return result;
      }

      // Helper: attempt to split one assignment into two pieces of
      // [durA] and [durB] days, placed in two different free (slot+days).
      // Returns true and mutates _assignments on success; reverts on failure.
      bool trySplit(int idx, int durA, int durB) {
        final orig = _assignments[idx];
        // GUARD: only auto-assigned, only bachelors — NEVER intermediate
        if (!orig.autoAssigned) return false;
        if (orig.classModel.level != EducationLevel.bachelors) return false;
        // GUARD: credit hours must equal durA + durB (no eating)
        if (durA + durB != orig.duration) return false;

        final shiftAllowed =
            effectiveAllowedSlotsForClass(orig.classModel.id, workingDays);
        final clashBefore = countClashes();

        // Temporarily remove original so searches don't see it as a blocker
        _assignments.removeAt(idx);

        // Search for two non-overlapping (slot, days) placements
        final eligibleSlots = _timeSlots.where((t) =>
            t.level == orig.classModel.level &&
            (shiftAllowed == null || shiftAllowed.contains(t.id)));

        for (final slotA in eligibleSlots) {
          for (int sdA = 1; sdA <= workingDays - durA + 1; sdA++) {
            final daysA = List<int>.generate(durA, (k) => sdA + k);
            if (!_areDaysFreeInSlot(daysA, slotA, orig.teacher.id,
                orig.classModel.id, orig.roomId, '__split_A__')) { continue; }

            for (final slotB in eligibleSlots) {
              // The two pieces MUST be in different periods OR different days
              for (int sdB = 1; sdB <= workingDays - durB + 1; sdB++) {
                final daysB = List<int>.generate(durB, (k) => sdB + k);
                // They must not share any days in the same slot
                if (slotA.id == slotB.id &&
                    daysA.toSet().intersection(daysB.toSet()).isNotEmpty) {
                  continue;
                }
                if (!_areDaysFreeInSlot(daysB, slotB, orig.teacher.id,
                    orig.classModel.id, orig.roomId, '__split_B__')) { continue; }

                // Tentatively create the two pieces
                final pieceA = orig.copyWith(
                  id: _uid(),
                  timeSlotId: slotA.id,
                  startSlot: sdA,
                  duration: durA,
                  customDays: <int>[],
                );
                final pieceB = orig.copyWith(
                  id: _uid(),
                  timeSlotId: slotB.id,
                  startSlot: sdB,
                  duration: durB,
                  customDays: <int>[],
                );
                _assignments.add(pieceA);
                _assignments.add(pieceB);

                if (countClashes() < clashBefore) {
                  messages.add(
                      '[Split ✓] "${orig.course.code}" (${orig.classModel.shortCode}) '
                      '${orig.duration}cr → ${durA}cr @ ${slotA.shortLabel} '
                      '${daysA.map((d) => _dayNames[d - 1]).join("–")} + '
                      '${durB}cr @ ${slotB.shortLabel} '
                      '${daysB.map((d) => _dayNames[d - 1]).join("–")}. '
                      'Run Fix Now again to re-merge if space later opens.');
                  return true;
                }

                // Revert the two pieces — didn't help
                _assignments.removeWhere(
                    (a) => a.id == pieceA.id || a.id == pieceB.id);
              }
            }
          }
        }

        // No valid split found — restore original at its index
        _assignments.insert(idx, orig);
        return false;
      }

      // ── Phase 2: split Bachelor 2cr courses (1+1) ─────────────────────────
      final phase2Clashing = stillClashingBachIdx();
      if (phase2Clashing.isNotEmpty) {
        // Candidates: auto-assigned Bachelor assignments with duration == 2
        // Use a snapshot of indices because list length may change during splits
        bool anyPhase2Split = false;
        // Iterate from the END so removals don't shift earlier indices
        final cands2 = phase2Clashing.toList()
          ..retainWhere((i) =>
              i < _assignments.length &&
              _assignments[i].duration == 2 &&
              _assignments[i].classModel.level == EducationLevel.bachelors &&
              _assignments[i].autoAssigned)
          ..sort((a2, b2) => b2.compareTo(a2)); // descending index order

        for (final idx in cands2) {
          if (idx >= _assignments.length) continue;
          if (trySplit(idx, 1, 1)) {
            anyPhase2Split = true;
            foundClash = true;
          }
        }
        if (anyPhase2Split) {
          messages.add('[Split Phase 2] Split ${cands2.length} Bachelor 2cr '
              'course(s) into 1+1 to resolve remaining clashes.');
        }
      }

      // ── Phase 3: split Bachelor 3cr courses (2+1) — only if phase 2 left
      //    clashes remaining ──────────────────────────────────────────────────
      final phase3Clashing = stillClashingBachIdx();
      if (phase3Clashing.isNotEmpty) {
        bool anyPhase3Split = false;
        final cands3 = phase3Clashing.toList()
          ..retainWhere((i) =>
              i < _assignments.length &&
              _assignments[i].duration == 3 &&
              _assignments[i].classModel.level == EducationLevel.bachelors &&
              _assignments[i].autoAssigned)
          ..sort((a2, b2) => b2.compareTo(a2)); // descending index order

        for (final idx in cands3) {
          if (idx >= _assignments.length) continue;
          if (trySplit(idx, 2, 1)) {
            anyPhase3Split = true;
            foundClash = true;
          }
        }
        if (anyPhase3Split) {
          messages.add('[Split Phase 3] Split ${cands3.length} Bachelor 3cr '
              'course(s) into 2+1 to resolve remaining clashes.');
        }
      }
    }

    // ── Report (unfixable) elective-vs-elective clashes ──

    // Two different elective groups can't be auto-moved — each owns a fixed
    // period for its own class pool — so surface these instead of silently
    // leaving them in the clash count.
    for (int i = 0; i < _electiveGroups.length; i++) {
      final egA = _electiveGroups[i];
      final slotA = _timeSlots.where((t) => t.id == egA.timeSlotId).firstOrNull;
      if (slotA == null) continue;
      for (int j = i + 1; j < _electiveGroups.length; j++) {
        final egB = _electiveGroups[j];
        final slotB = _timeSlots.where((t) => t.id == egB.timeSlotId).firstOrNull;
        if (slotB == null || !_slotsOverlap(slotA, slotB)) continue;

        final sharedClasses =
            egA.classIds.toSet().intersection(egB.classIds.toSet());
        final sharedTeachers = egA.entries
            .map((e) => e.teacherId)
            .toSet()
            .intersection(egB.entries.map((e) => e.teacherId).toSet());
        final sharedRooms = egA.entries
            .map((e) => e.roomId)
            .whereType<String>()
            .toSet()
            .intersection(
                egB.entries.map((e) => e.roomId).whereType<String>().toSet());

        if (sharedClasses.isEmpty && sharedTeachers.isEmpty && sharedRooms.isEmpty) {
          continue;
        }
        messages.add(
            '[Elective] Cannot auto-fix: elective groups at ${slotA.shortLabel} '
            'and ${slotB.shortLabel} overlap and share '
            '${sharedClasses.isNotEmpty ? "a class" : sharedTeachers.isNotEmpty ? "a teacher" : "a room"} '
            '— adjust these elective groups manually.');
      }
    }

    if (messages.isNotEmpty) {
      // Flag that the NEXT snapshot from Firestore is our own write echo Ã¢â‚¬â€
      // the listener must skip it so it doesn't overwrite the in-memory fix.
      notifyListeners(); // redraw matrix immediately with clean in-memory data
      _saveData(); // persist the fix to Firestore in the background
    }
    // An unresolvable pair can be re-encountered on more than one pass once
    // other clashes elsewhere keep the loop going — dedupe so the summary
    // dialog doesn't show the same "could not relocate" line repeatedly.
    return messages.toSet().toList();
    } finally {
      _isFixing = false;
    }
  }

  /// What-if engine: for every current clash, propose concrete DATA changes
  /// (teacher swap, day split, room change) that are verified free against
  /// the whole existing timetable. Strictly read-only — each suggestion is
  /// applied only via its own [FixSuggestion.apply] (an explicit user
  /// click), which re-validates first. Manual (pinned) and combined-rule
  /// cards are never candidates, and no other card moves, so applying a
  /// suggestion removes its clash without creating new ones.
  Map<String, List<FixSuggestion>> suggestFixes({int workingDays = 6}) {
    final out = <String, List<FixSuggestion>>{};
    final combinedCourseIds = _combinedRules.map((r) => r.courseId).toSet();
    // Deleted rooms leave stale roomId references on old assignments —
    // ignore those as a "room clash" signal, matching countClashes().
    final validRoomIds = {for (final r in _rooms) r.id};
    // Eligible movers: unpinned and not combined-protected.
    bool eligible(Assignment x) =>
        x.autoAssigned && !combinedCourseIds.contains(x.course.id);

    String label(Assignment a) =>
        '${a.course.name} (${a.classModel.shortCode})';
    String dayStr(List<int> days) =>
        days.map((d) => _dayNames[d - 1]).join(', ');

    // Teacher load, for ranking candidates (fewest assignments first).
    final load = <String, int>{};
    for (final a in _assignments) {
      load[a.teacher.id] = (load[a.teacher.id] ?? 0) + 1;
    }

    bool freeFor(Assignment a,
        {String? teacherId, String? roomId, TimeSlot? slot, List<int>? days}) {
      final s =
          slot ?? _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      if (s == null) return false;
      return _areDaysFreeInSlot(days ?? a.occupiedSlots, s,
          teacherId ?? a.teacher.id, a.classModel.id, roomId ?? a.roomId, a.id);
    }

    // ── Suggestion builders ──────────────────────────────────────────────
    FixSuggestion teacherSwap(String clash, Assignment a, Teacher t) =>
        FixSuggestion(
          clash: clash,
          description:
              'Assign "${label(a)}" to ${t.name} instead of ${a.teacher.name} '
              '— keeps its current period and days; ${t.name} is free there.',
          apply: () {
            final i = _assignments.indexWhere((x) => x.id == a.id);
            if (i == -1) return 'Not applied: ${label(a)} changed meanwhile.';
            final cur = _assignments[i];
            if (!cur.autoAssigned) {
              return 'Not applied: ${label(a)} is a manual allocation.';
            }
            if (!freeFor(cur, teacherId: t.id)) {
              return 'Not applied: ${t.name} is no longer free there.';
            }
            _assignments[i] = cur.copyWith(teacher: t);
            notifyListeners();
            _saveData();
            return 'Done: ${label(a)} is now taught by ${t.name}.';
          },
        );

    List<Teacher> teacherCandidates(Assignment a) {
      final dept = a.teacher.department.trim().toLowerCase();
      final cands = _teachers
          .where((t) =>
              t.id != a.teacher.id &&
              t.department.trim().toLowerCase() == dept &&
              freeFor(a, teacherId: t.id))
          .toList()
        ..sort((x, y) => (load[x.id] ?? 0).compareTo(load[y.id] ?? 0));
      return cands.take(3).toList();
    }

    // Alternate teachers who could plausibly take over `a` at a DIFFERENT
    // period (unlike [teacherCandidates], which only checks a's current
    // slot). Prefer teachers already proven on this exact course elsewhere;
    // fall back to same-department. Availability at any given period is
    // checked by the caller via _findFreeDayAndSlot on a hypothetical copy.
    List<Teacher> altTeacherCandidatesForMove(Assignment a) {
      final provenOnCourse = _teachers
          .where((t) =>
              t.id != a.teacher.id &&
              _assignments
                  .any((x) => x.course.id == a.course.id && x.teacher.id == t.id))
          .toList();
      final dept = a.teacher.department.trim().toLowerCase();
      final pool = provenOnCourse.isNotEmpty
          ? provenOnCourse
          : _teachers
              .where((t) =>
                  t.id != a.teacher.id &&
                  t.department.trim().toLowerCase() == dept)
              .toList();
      pool.sort((x, y) => (load[x.id] ?? 0).compareTo(load[y.id] ?? 0));
      return pool.take(5).toList();
    }

    // One free (period, day) cell per needed day — single-day cells can
    // exist where the whole-block search of Fix Now finds nothing.
    List<({TimeSlot slot, int day})>? splitCells(Assignment a) {
      final allowed =
          effectiveAllowedSlotsForClass(a.classModel.id, workingDays);
      final slots = _timeSlots
          .where((t) =>
              t.level == a.classModel.level &&
              (allowed == null || allowed.contains(t.id)))
          .toList();
      final need = a.occupiedSlots.length;
      final cells = <({TimeSlot slot, int day})>[];
      for (int d = 1; d <= workingDays && cells.length < need; d++) {
        for (final s in slots) {
          if (freeFor(a, slot: s, days: [d])) {
            cells.add((slot: s, day: d));
            break;
          }
        }
      }
      return cells.length == need ? cells : null;
    }

    FixSuggestion daySplit(
            String clash, Assignment a, List<({TimeSlot slot, int day})> cells) =>
        FixSuggestion(
          clash: clash,
          description: 'Split "${label(a)}" into single days: '
              '${cells.map((c) => '${_dayNames[c.day - 1]} @ ${c.slot.shortLabel}').join(', ')} '
              '— every cell is free for the class, teacher and room.',
          apply: () {
            final i = _assignments.indexWhere((x) => x.id == a.id);
            if (i == -1) return 'Not applied: ${label(a)} changed meanwhile.';
            final cur = _assignments[i];
            if (!cur.autoAssigned) {
              return 'Not applied: ${label(a)} is a manual allocation.';
            }
            final fresh = splitCells(cur);
            if (fresh == null) {
              return 'Not applied: those cells are no longer free.';
            }
            _assignments.removeAt(i);
            for (final c in fresh) {
              _assignments.add(cur.copyWith(
                id: _uid(),
                timeSlotId: c.slot.id,
                startSlot: c.day,
                duration: 1,
                customDays: const [],
              ));
            }
            notifyListeners();
            _saveData();
            return 'Done: ${label(cur)} split across '
                '${fresh.map((c) => '${_dayNames[c.day - 1]} @ ${c.slot.shortLabel}').join(', ')}.';
          },
        );

    FixSuggestion roomSwap(String clash, Assignment a, Room r) => FixSuggestion(
          clash: clash,
          description:
              'Move "${label(a)}" to room ${r.name} — free at its period '
              'and days.',
          apply: () {
            final i = _assignments.indexWhere((x) => x.id == a.id);
            if (i == -1) return 'Not applied: ${label(a)} changed meanwhile.';
            final cur = _assignments[i];
            if (!cur.autoAssigned) {
              return 'Not applied: ${label(a)} is a manual allocation.';
            }
            if (!freeFor(cur, roomId: r.id)) {
              return 'Not applied: room ${r.name} is no longer free.';
            }
            _assignments[i] = cur.copyWith(roomId: r.id);
            notifyListeners();
            _saveData();
            return 'Done: ${label(a)} moved to room ${r.name}.';
          },
        );

    // ── Fallback builders: whole-block move / three-way period swap ──────
    // Only used when the type-specific suggestions above found nothing, so
    // existing suggestion output is unchanged. Both reuse the verified
    // rule-aware helpers (_findFreeDayAndSlot / _areDaysFreeInSlot):
    // level, shift restriction, Friday-blocked slots and electives are all
    // enforced there — no new rule logic here.
    String cellsStr(List<int> days, TimeSlot s) =>
        '${dayStr(days)} @ ${s.shortLabel}';

    FixSuggestion slotMove(String clash, Assignment a,
            ({List<int> days, TimeSlot slot}) free) =>
        FixSuggestion(
          clash: clash,
          description:
              'Move "${label(a)}" whole to ${cellsStr(free.days, free.slot)} '
              '— same teacher and room; the block is free there.',
          apply: () {
            final i = _assignments.indexWhere((x) => x.id == a.id);
            if (i == -1) return 'Not applied: ${label(a)} changed meanwhile.';
            final cur = _assignments[i];
            if (!cur.autoAssigned) {
              return 'Not applied: ${label(a)} is a manual allocation.';
            }
            final fresh = _findFreeDayAndSlot(cur,
                excludeAssignmentId: cur.id, maxDay: workingDays);
            if (fresh == null) {
              return 'Not applied: no free block any more.';
            }
            _assignments[i] = cur.copyWith(
              id: _uid(),
              timeSlotId: fresh.slot.id,
              startSlot: fresh.days.first,
              duration: fresh.days.length,
              customDays: const [],
            );
            notifyListeners();
            _saveData();
            return 'Done: ${label(cur)} moved to '
                '${cellsStr(fresh.days, fresh.slot)}.';
          },
        );

    // Swap validity: both cards trade their (period, days) blocks. Same
    // day-count required (otherwise the trade changes teaching days), and
    // every rule the single movers respect is cross-checked both ways.
    bool swapOk(Assignment x, TimeSlot sx, Assignment y, TimeSlot sy) {
      final xd = List<int>.from(x.occupiedSlots)..sort();
      final yd = List<int>.from(y.occupiedSlots)..sort();
      if (xd.length != yd.length) return false;
      if (sx.id == sy.id && xd.join(',') == yd.join(',')) {
        return false; // identical cells — swapping changes nothing
      }
      if (sy.level != x.classModel.level || sx.level != y.classModel.level) {
        return false;
      }
      final ax = effectiveAllowedSlotsForClass(x.classModel.id, workingDays);
      if (ax != null && !ax.contains(sy.id)) return false;
      final ay = effectiveAllowedSlotsForClass(y.classModel.id, workingDays);
      if (ay != null && !ay.contains(sx.id)) return false;
      return _areDaysFreeInSlot(yd, sy, x.teacher.id, x.classModel.id,
              x.roomId, x.id,
              excludeId2: y.id) &&
          _areDaysFreeInSlot(xd, sx, y.teacher.id, y.classModel.id, y.roomId,
              y.id,
              excludeId2: x.id);
    }

    Assignment? swapPartner(Assignment a) {
      final sa = _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      if (sa == null) return null;
      // ponytail: O(n²) scan — only runs when every cheaper fix failed.
      for (final c in _assignments) {
        if (c.id == a.id || !eligible(c)) continue;
        if (_lockedSlotIdFor(c) != null) continue; // never pull c off its lock
        final sc = _timeSlots.where((t) => t.id == c.timeSlotId).firstOrNull;
        if (sc == null) continue;
        if (swapOk(a, sa, c, sc)) return c;
      }
      return null;
    }

    FixSuggestion pairSwap(String clash, Assignment a, Assignment c) =>
        FixSuggestion(
          clash: clash,
          description: 'Swap periods: "${label(a)}" ↔ "${label(c)}" — each '
              'takes the other\'s days and period; both spots verified free.',
          apply: () {
            final ia = _assignments.indexWhere((x) => x.id == a.id);
            final ic = _assignments.indexWhere((x) => x.id == c.id);
            if (ia == -1 || ic == -1) {
              return 'Not applied: one of the cards changed meanwhile.';
            }
            final ca = _assignments[ia];
            final cc = _assignments[ic];
            if (!ca.autoAssigned || !cc.autoAssigned) {
              return 'Not applied: a manual allocation is involved.';
            }
            if (combinedCourseIds.contains(ca.course.id) ||
                combinedCourseIds.contains(cc.course.id)) {
              return 'Not applied: a combined course is involved.';
            }
            final sa =
                _timeSlots.where((t) => t.id == ca.timeSlotId).firstOrNull;
            final sc =
                _timeSlots.where((t) => t.id == cc.timeSlotId).firstOrNull;
            if (sa == null || sc == null || !swapOk(ca, sa, cc, sc)) {
              return 'Not applied: the swap is no longer clash-free.';
            }
            Assignment place(Assignment src, Assignment dst) {
              final days = List<int>.from(dst.occupiedSlots)..sort();
              final consec = days.length == days.last - days.first + 1;
              return src.copyWith(
                id: _uid(),
                timeSlotId: dst.timeSlotId,
                startSlot: days.first,
                duration: days.length,
                customDays: consec ? const [] : days,
              );
            }
            _assignments[ia] = place(ca, cc);
            _assignments[ic] = place(cc, ca);
            notifyListeners();
            _saveData();
            return 'Done: swapped "${label(ca)}" ↔ "${label(cc)}".';
          },
        );

    FixSuggestion teacherReassignMove(String clash, Assignment a, Teacher t,
            ({List<int> days, TimeSlot slot}) free) =>
        FixSuggestion(
          clash: clash,
          description:
              'Reassign "${label(a)}" to ${t.name} and move it to '
              '${cellsStr(free.days, free.slot)} — ${a.teacher.name} has no '
              'free block for this anywhere else, but ${t.name} does.',
          apply: () {
            final i = _assignments.indexWhere((x) => x.id == a.id);
            if (i == -1) return 'Not applied: ${label(a)} changed meanwhile.';
            final cur = _assignments[i];
            if (!cur.autoAssigned) {
              return 'Not applied: ${label(a)} is a manual allocation.';
            }
            final probe = cur.copyWith(teacher: t);
            final fresh = _findFreeDayAndSlot(probe,
                excludeAssignmentId: cur.id, maxDay: workingDays);
            if (fresh == null) {
              return 'Not applied: no free block for ${t.name} any more.';
            }
            _assignments[i] = cur.copyWith(
              id: _uid(),
              teacher: t,
              timeSlotId: fresh.slot.id,
              startSlot: fresh.days.first,
              duration: fresh.days.length,
              customDays: const [],
            );
            notifyListeners();
            _saveData();
            return 'Done: ${label(cur)} now taught by ${t.name} at '
                '${cellsStr(fresh.days, fresh.slot)}.';
          },
        );

    void addFallbacks(
        String clash, List<FixSuggestion> sug, List<Assignment> cards) {
      if (sug.isNotEmpty) return;
      // Lock-bound cards must stay in their locked period — never suggest
      // moving/swapping them elsewhere (mirrors the Fix Now lock guards).
      for (final card
          in cards.where((x) => eligible(x) && _lockedSlotIdFor(x) == null)) {
        final free = _findFreeDayAndSlot(card,
            excludeAssignmentId: card.id, maxDay: workingDays);
        if (free != null) {
          sug.add(slotMove(clash, card, free));
          return;
        }
      }
      for (final card
          in cards.where((x) => eligible(x) && _lockedSlotIdFor(x) == null)) {
        final partner = swapPartner(card);
        if (partner != null) {
          sug.add(pairSwap(clash, card, partner));
          return;
        }
      }
      // Last resort: the card's own teacher has no free block anywhere, but
      // an alternate qualified teacher might — try each candidate until one
      // actually opens up a slot (probed via a hypothetical teacher swap,
      // no shared logic duplicated with Fix Now's own search).
      for (final card
          in cards.where((x) => eligible(x) && _lockedSlotIdFor(x) == null)) {
        for (final t in altTeacherCandidatesForMove(card)) {
          final probe = card.copyWith(teacher: t);
          final free = _findFreeDayAndSlot(probe,
              excludeAssignmentId: card.id, maxDay: workingDays);
          if (free != null) {
            sug.add(teacherReassignMove(clash, card, t, free));
            return;
          }
        }
      }
    }

    bool isCombinedMatch(Assignment a, Assignment b) {
      if (a.course.id != b.course.id) return false;
      return _combinedRules.any((r) =>
          r.courseId == a.course.id &&
          r.classIds.contains(a.classModel.id) &&
          r.classIds.contains(b.classModel.id));
    }

    // ── Clash pair scan (read-only, mirrors fixTeacherClashes detection) ─
    for (int i = 0; i < _assignments.length; i++) {
      final a = _assignments[i];
      final slotA = _timeSlots.where((t) => t.id == a.timeSlotId).firstOrNull;
      for (int j = i + 1; j < _assignments.length; j++) {
        final b = _assignments[j];
        final slotB =
            _timeSlots.where((t) => t.id == b.timeSlotId).firstOrNull;
        final overlap = a.timeSlotId == b.timeSlotId ||
            (slotA != null && slotB != null && _slotsOverlap(slotA, slotB));
        if (!overlap) continue;
        final shared =
            a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
        if (shared.isEmpty) continue;
        if (isCombinedMatch(a, b)) continue;

        final sharedDays = shared.toList()..sort();

        if (a.teacher.id == b.teacher.id) {
          final clash = 'Teacher ${a.teacher.name}: ${label(a)} ↔ ${label(b)} '
              'on ${dayStr(sharedDays)}';
          final sug = <FixSuggestion>[];
          // Prefer re-teaching the Bachelor card (matches standing advice);
          // try both eligible cards.
          final ordered = [a, b]..sort((x, y) =>
              (x.classModel.level == EducationLevel.bachelors ? 0 : 1)
                  .compareTo(
                      y.classModel.level == EducationLevel.bachelors ? 0 : 1));
          for (final card in ordered.where(eligible)) {
            for (final t in teacherCandidates(card)) {
              sug.add(teacherSwap(clash, card, t));
            }
            if (sug.isNotEmpty) break;
          }
          addFallbacks(clash, sug, ordered);
          out[clash] = sug;
        } else if (a.classModel.id == b.classModel.id) {
          final clash = 'Class ${a.classModel.shortCode}: ${label(a)} ↔ '
              '${label(b)} on ${dayStr(sharedDays)}';
          final sug = <FixSuggestion>[];
          // Split the smaller eligible Bachelor 2–3 cr card into single days.
          final ordered = [a, b]
            ..sort((x, y) =>
                x.occupiedSlots.length.compareTo(y.occupiedSlots.length));
          for (final card in ordered.where((x) =>
              eligible(x) &&
              _lockedSlotIdFor(x) == null && // day-split scatters across slots
              x.classModel.level == EducationLevel.bachelors &&
              x.course.creditHours >= 2 &&
              x.course.creditHours <= 3)) {
            final cells = splitCells(card);
            if (cells != null) {
              sug.add(daySplit(clash, card, cells));
              break;
            }
          }
          addFallbacks(clash, sug, ordered);
          out[clash] = sug;
        } else if (a.hasRoom &&
            b.hasRoom &&
            a.roomId == b.roomId &&
            validRoomIds.contains(a.roomId)) {
          final roomName =
              _rooms.where((r) => r.id == a.roomId).firstOrNull?.name ??
                  a.roomId;
          final clash = 'Room $roomName: ${label(a)} ↔ ${label(b)} '
              'on ${dayStr(sharedDays)}';
          final sug = <FixSuggestion>[];
          for (final card in [a, b].where(eligible)) {
            final r = _rooms
                .where((r) => r.id != card.roomId && freeFor(card, roomId: r.id))
                .firstOrNull;
            if (r != null) {
              sug.add(roomSwap(clash, card, r));
              break;
            }
          }
          addFallbacks(clash, sug, [a, b]);
          out[clash] = sug;
        }
      }
    }
    return out;
  }
}