import 'package:flutter/material.dart';
import '../models/assignment.dart';
import '../models/teacher.dart';
import '../models/course.dart';
import '../models/class_model.dart';
import '../models/room.dart';
import '../models/time_slot.dart';
import '../models/time_slot_lock.dart';
import '../models/education_level.dart';
import '../services/ga_engine.dart';
import '../services/csp_scheduler.dart';
import '../services/cancelable_ga_run.dart';
import '../models/combined_rule.dart';
import '../models/elective_group.dart';
import 'allocator_viewmodel.dart';
import 'data_entry_viewmodel.dart';

// Status enum — same as before so the UI doesn't need changes
enum GaStatus { idle, running, done, failed }

// ─────────────────────────────────────────────────────────────────────────────
// Result (mirrors what the UI expects)
// ─────────────────────────────────────────────────────────────────────────────
class GaScheduleResult {
  final String         message;
  final int            totalClashes;
  final int            generationsRun;
  final Map<String, int> breakdown;

  /// Clashes between two MANUALLY PINNED assignments — no algorithm can fix
  /// these automatically. Each string is a human-readable description of
  /// the specific conflict (teacher name, course names, slot label).
  final List<String>   pinnedClashes;

  const GaScheduleResult({
    required this.message,
    required this.totalClashes,
    required this.generationsRun,
    required this.breakdown,
    this.pinnedClashes = const [],
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ViewModel
// ─────────────────────────────────────────────────────────────────────────────
class BackendViewModel extends ChangeNotifier {
  GaStatus          _status      = GaStatus.idle;
  GaScheduleResult? _lastResult;
  String?           _errorMessage;
  void Function()?  _activeCancel;
  bool              _cancelRequested = false;

  GaStatus          get status       => _status;
  GaScheduleResult? get lastResult   => _lastResult;
  String?           get errorMessage => _errorMessage;
  bool              get isRunning    => _status == GaStatus.running;

  /// Kills the worker isolate mid-run. Safe to call any time — a no-op
  /// unless a run is actually in progress.
  void cancelGA() {
    if (_status != GaStatus.running) return;
    _cancelRequested = true;
    _activeCancel?.call();
    _status       = GaStatus.idle;
    _errorMessage = null;
    _lastResult   = null;
    notifyListeners();
  }

  // ── Run GA ─────────────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────────────────────
  // Pre-run pinned-clash detector.
  // Scans all MANUALLY PINNED (autoAssigned=false) assignments for clashes
  // among themselves — teacher double-booking and section double-booking at
  // clock-overlapping slots on the same day(s). Only examines pinned pairs;
  // free assignments are handled by GA/CSP and are NOT reported here.
  // No allocations are changed — read-only diagnostic.
  // ─────────────────────────────────────────────────────────────────────────
  static List<String> _detectPinnedClashes(
    List<Assignment>   assignments,
    List<TimeSlot>     timeSlots,
    int                workingDays,
  ) {
    // Only look at pinned assignments
    final pinned = assignments.where((a) => !a.autoAssigned).toList();
    if (pinned.length < 2) return const [];

    // Pre-compute clock bounds [start_min, end_min] per slot
    int toMin(String t) {
      final p = t.split(':');
      if (p.length != 2) return -1;
      return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
    }
    final slotBounds = <String, (int, int)>{
      for (final ts in timeSlots)
        ts.id: (toMin(ts.startTime), toMin(ts.endTime)),
    };

    bool clockOverlap(String slotA, String slotB) {
      if (slotA == slotB) return true;
      final a = slotBounds[slotA], b = slotBounds[slotB];
      if (a == null || b == null) return false;
      if (a.$1 < 0 || b.$1 < 0) return false;
      return a.$1 < b.$2 && b.$1 < a.$2;
    }

    // Returns the occupied day numbers for a pinned assignment
    List<int> occupiedDays(Assignment a) {
      if (a.customDays.isNotEmpty) return a.customDays;
      return List.generate(a.duration, (k) => (a.startSlot + k).clamp(1, workingDays));
    }

    final conflicts = <String>{};
    for (int i = 0; i < pinned.length; i++) {
      for (int j = i + 1; j < pinned.length; j++) {
        final a = pinned[i], b = pinned[j];
        // No constraint between them → skip
        final sameTeacher = a.teacher.id.isNotEmpty && a.teacher.id == b.teacher.id;
        // Bachelor-only: two different courses, two different teachers, same
        // class/section, same time — an allowed parallel session, not a clash.
        final bachelorParallel = a.classModel.level == EducationLevel.bachelors &&
            b.classModel.level == EducationLevel.bachelors && !sameTeacher;
        final sameSection = !bachelorParallel &&
            a.classModel.id == b.classModel.id &&
            a.classModel.shortCode == b.classModel.shortCode &&
            a.course.id != b.course.id;
        if (!sameTeacher && !sameSection) continue;
        // Check clock overlap
        if (!clockOverlap(a.timeSlotId, b.timeSlotId)) continue;
        // Check day overlap
        final daysA = occupiedDays(a), daysB = occupiedDays(b);
        final dayClash = daysA.any(daysB.contains);
        if (!dayClash) continue;
        // Build a readable conflict description
        final slotLabel = timeSlots
            .where((ts) => ts.id == a.timeSlotId)
            .firstOrNull
            ?.shortLabel ?? a.timeSlotId;
        final slotLabelB = timeSlots
            .where((ts) => ts.id == b.timeSlotId)
            .firstOrNull
            ?.shortLabel ?? b.timeSlotId;
        final dayNames = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
        final clashDays = daysA
            .where(daysB.contains)
            .map((d) => d >= 1 && d <= 7 ? dayNames[d - 1] : 'd$d')
            .join(', ');
        final reason = sameTeacher
            ? '${a.teacher.name}: "${a.course.name}" (${a.classModel.shortCode} @ $slotLabel) '
              '↔ "${b.course.name}" (${b.classModel.shortCode} @ $slotLabelB) '
              '— same teacher pinned to overlapping slots on $clashDays'
            : '${a.classModel.shortCode}: "${a.course.name}" (@ $slotLabel) '
              '↔ "${b.course.name}" (@ $slotLabelB) '
              '— same class pinned to overlapping slots on $clashDays';
        conflicts.add(reason);
      }
    }
    return conflicts.toList()..sort();
  }

  // True if the card's DAYS hit an elective reservation in this slot for its
  // class or teacher. Electives only occupy the first N days of their period
  // (N = max credit hours of the group), so a manual card on the leftover
  // days keeps its lock. Maps are keyed '$classId|$slotId' / '$teacherId|$slotId'.
  static bool _slotElectiveBlocked(
      String slotId, String classId, String teacherId, List<int> cardDays,
      Map<String, Set<int>> electiveClassBlockDays,
      Map<String, Set<int>> electiveTeacherBlockDays) {
    final byClass = electiveClassBlockDays['$classId|$slotId'];
    if (byClass != null && cardDays.any(byClass.contains)) return true;
    final byTeacher = electiveTeacherBlockDays['$teacherId|$slotId'];
    if (byTeacher != null && cardDays.any(byTeacher.contains)) return true;
    return false;
  }

  Future<void> runGA({
    required List<Teacher>      teachers,
    required List<Course>       courses,
    required List<ClassModel>   classes,
    required List<Room>         rooms,
    required List<TimeSlot>     timeSlots,
    required List<Assignment>   assignments,
    required List<TimeSlotLock> timeSlotLocks,
    required List<CombinedClassRule> combinedRules,
    required List<ElectiveGroup> electiveGroups,
    required AllocatorViewModel allocVm,
    DataEntryViewModel? dataVm,   // when provided, GA results write back to the main data
    // classId → set of allowed slot IDs (shift constraint). If provided,
    // the GA will only place that class in the listed time slots.
    Map<String, Set<String>> shiftClassAllowed = const {},
    int  workingDays    = 6,
    int  maxPeriods     = 6,
    int  populationSize = 80,
    int  maxGenerations = 300,
    int  stagnationLimit = 40,
  }) async {
    if (assignments.isEmpty) {
      _errorMessage = 'No assignments found.\nPlease add at least one assignment in the Allocator first.';
      _status = GaStatus.failed;
      notifyListeners();
      return;
    }

    _status          = GaStatus.running;
    _errorMessage    = null;
    _lastResult      = null;
    _cancelRequested = false;
    notifyListeners();

    try {
      // ── 1b. Build elective block maps ────────────────────────────────────────
      // Tells the GA which time slots are reserved for elective groups so that
      // regular assignments for those classes / teachers are never placed there.
      // CRITICAL: blocks include ALL clock-overlapping slots (cross-level too),
      // not just the exact slot ID — a Bach slot overlapping an Inter elective
      // in real clock time must also be blocked.
      final Map<String, Set<String>> electiveClassBlocks   = {};
      final Map<String, Set<String>> electiveTeacherBlocks = {};

      // Pre-compute clock bounds for every slot
      int toMin(String t) {
        final p = t.split(':');
        if (p.length != 2) return -1;
        return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
      }
      final slotBounds = {
        for (final t in timeSlots) t.id: (s: toMin(t.startTime), e: toMin(t.endTime))
      };

      // All slot IDs that clock-overlap the given slot (including itself)
      List<String> overlappingSlots(String slotId) {
        final base = slotBounds[slotId];
        if (base == null || base.s < 0 || base.e < 0) return [slotId];
        return timeSlots
            .where((t) {
              final o = slotBounds[t.id];
              if (o == null || o.s < 0 || o.e < 0) return t.id == slotId;
              return base.s < o.e && o.s < base.e; // real clock overlap
            })
            .map((t) => t.id)
            .toList();
      }

      // Days the group actually occupies: first N days, N = max credit hours
      // among its entries (matches DataEntryViewModel.electiveOccupiedDays).
      Set<int> egDays(ElectiveGroup eg) {
        int maxCr = 1;
        for (final e in eg.entries) {
          final cr = courses.where((c) => c.id == e.courseId).firstOrNull?.creditHours ?? 3;
          if (cr > maxCr) maxCr = cr;
        }
        return {for (int d = 1; d <= maxCr; d++) d};
      }

      // Day-aware variant used by the manual-lock check ('$id|$slotId' → days).
      final Map<String, Set<int>> electiveClassBlockDays   = {};
      final Map<String, Set<int>> electiveTeacherBlockDays = {};

      for (final eg in electiveGroups) {
        if (eg.timeSlotId.isEmpty) continue;
        final blocked = overlappingSlots(eg.timeSlotId);
        final days = egDays(eg);
        // Only a full-week elective removes the whole slot from the domain.
        // Partial-week electives (e.g. 2 cr = days 1-2) are enforced by the
        // day-aware phantom occupancy instead, so their leftover days stay
        // usable for regular courses of the same classes/teachers.
        final fullWeek = days.length >= workingDays;

        // Block every class that attends this elective group
        for (final classId in eg.classIds) {
          if (fullWeek) {
            electiveClassBlocks.putIfAbsent(classId, () => {}).addAll(blocked);
          }
          for (final s in blocked) {
            electiveClassBlockDays.putIfAbsent('$classId|$s', () => {}).addAll(days);
          }
        }

        // Block every teacher who teaches an entry in this elective group
        for (final entry in eg.entries) {
          if (entry.teacherId.isNotEmpty) {
            if (fullWeek) {
              electiveTeacherBlocks.putIfAbsent(entry.teacherId, () => {}).addAll(blocked);
            }
            for (final s in blocked) {
              electiveTeacherBlockDays.putIfAbsent('${entry.teacherId}|$s', () => {}).addAll(days);
            }
          }
        }
      }

      // ── 1c. Elective occupancy for the fitness function ─────────────────────
      // Phantom entries: the GA counts a HARD clash whenever a regular assignment
      // lands on a (day, slot) cell occupied by an elective for the same class/teacher.
      final electiveOccupancy = <Map<String, dynamic>>[];
      for (final eg in electiveGroups) {
        if (eg.timeSlotId.isEmpty) continue;
        for (final slotId in overlappingSlots(eg.timeSlotId)) {
          electiveOccupancy.add({
            'slot_id':     slotId,
            'class_ids':   eg.classIds.toList(),
            'teacher_ids': eg.entries.map((e) => e.teacherId).where((t) => t.isNotEmpty).toList(),
            // Only the first N days are occupied — leftover days stay free.
            'days':        egDays(eg).toList(),
          });
        }
      }


      // ── 1. Build assignment maps — grouping combined courses ─────────────
      final assignmentMaps = <Map<String, dynamic>>[];
      final List<List<int>> origIndicesMapping = [];

      final List<bool> processed = List.filled(assignments.length, false);

      for (int i = 0; i < assignments.length; i++) {
        if (processed[i]) continue;
        final a = assignments[i];

        // Find if this assignment matches any rule
        CombinedClassRule? matchedRule;
        for (final r in combinedRules) {
          if (r.courseId == a.course.id && r.classIds.contains(a.classModel.id)) {
            matchedRule = r;
            break;
          }
        }

        if (matchedRule != null) {
          // Group all matching assignments into one GA assignment
          final groupIndices = <int>[];
          for (int j = i; j < assignments.length; j++) {
            if (processed[j]) continue;
            final aj = assignments[j];
            if (aj.course.id == matchedRule.courseId && matchedRule.classIds.contains(aj.classModel.id)) {
              groupIndices.add(j);
              processed[j] = true;
            }
          }
          // A combined group must count as LOCKED if ANY member is pinned —
          // taking the flag from the first member only let an unpinned
          // sibling (from an unlocked program) unlock the whole gene, so
          // Selective Lock appeared to do nothing for combined courses.
          final lockSrc = groupIndices
              .map((gi) => assignments[gi])
              .firstWhere((x) => !x.autoAssigned, orElse: () => a);
          final isManualC = !lockSrc.autoAssigned;
          // Elective reservation wins over stale locks
          final lockHolds = isManualC &&
              !_slotElectiveBlocked(lockSrc.timeSlotId, lockSrc.classModel.id,
                  lockSrc.teacher.id, lockSrc.occupiedSlots,
                  electiveClassBlockDays, electiveTeacherBlockDays);
          assignmentMaps.add({
            'teacher_id':           a.teacher.id,
            'course_id':            a.course.id,
            'discipline_id':        a.classModel.id,
            'section':              a.classModel.shortCode,
            'room_id':              a.roomId,
            'level':                a.classModel.level.index,
            'credit_hours':         a.course.creditHours.clamp(1, workingDays),
            'locked_start_day':     lockHolds ? lockSrc.occupiedSlots.firstOrNull : null,
            'locked_time_slot_id':  lockHolds ? lockSrc.timeSlotId : null,
            // Rooms are manual-only — always locked for the GA regardless of
            // autoAssigned, so it never invents or reshuffles a room.
            'locked_room_id':       a.hasRoom ? a.roomId : null,
            'custom_days':          lockHolds ? lockSrc.customDays : const <int>[],
          });
          origIndicesMapping.add(groupIndices);
        } else {
          // Standard single assignment.
          // If manually assigned (autoAssigned=false), lock its days+period
          // so the GA preserves the user's choice exactly.
          processed[i] = true;
          final isManual = !a.autoAssigned;
          // Elective reservation wins over stale locks: if this class/teacher has an
          // elective in the manually-locked slot, release the lock so the GA moves it.
          final lockConflictsElective = isManual &&
              _slotElectiveBlocked(a.timeSlotId, a.classModel.id, a.teacher.id,
                  a.occupiedSlots, electiveClassBlockDays, electiveTeacherBlockDays);
          final manualStart = (isManual && !lockConflictsElective) ? a.occupiedSlots.firstOrNull : null;
          final manualTs    = (isManual && !lockConflictsElective) ? a.timeSlotId : null;
          final manualDays  = (isManual && !lockConflictsElective) ? a.customDays : const <int>[];
          assignmentMaps.add({
            'teacher_id':           a.teacher.id,
            'course_id':            a.course.id,
            'discipline_id':        a.classModel.id,
            'section':              a.classModel.shortCode,
            'room_id':              a.roomId,
            'level':                a.classModel.level.index,
            'credit_hours':         a.course.creditHours.clamp(1, workingDays),
            // Lock fields — GA will not mutate these if set
            'locked_start_day':     manualStart,   // int? — null = GA chooses
            'locked_time_slot_id':  manualTs,      // String? — null = GA chooses
            // Rooms are manual-only — always locked for the GA regardless of
            // autoAssigned, so it never invents or reshuffles a room.
            'locked_room_id':       a.hasRoom ? a.roomId : null,
            'custom_days':          manualDays,
          });
          origIndicesMapping.add([i]);
        }
      }

      // ── 2. Time slot mapping ──────────────────────────────────────────────
      final activeSlots = timeSlots.toList();

      final Map<String, List<String>> tsIdsByLevel = {};
      final Map<String, Map<String, int>> tsIntervals = {};

      for (final ts in activeSlots) {
        final lvlKey = ts.level.index.toString();
        tsIdsByLevel.putIfAbsent(lvlKey, () => []).add(ts.id);

        final startParts = ts.startTime.split(':');
        final endParts = ts.endTime.split(':');
        int s = 0; int e = 0;
        if (startParts.length == 2) s = int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
        if (endParts.length == 2) e = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

        tsIntervals[ts.id] = {'start': s, 'end': e};
      }

      // ── 3. Room IDs (null = any room) ─────────────────────────────────────
      final roomIds = <String?>[null, ...rooms.map((r) => r.id)];

      // ── 3.5 Shift overflow: expand allowed slots when credit hours exceed shift capacity ──
      // Capacity of a shift = number_of_slots_in_that_shift × workingDays
      // e.g. 3 morning slots × 6 days = 18 credit-hour capacity.
      // If a class's total credit hours exceed its shift capacity, the GA is
      // allowed to use the single adjacent boundary slot so the overflow course
      // can be scheduled there without hard-blocking it.
      //   Morning overflow → unlock first evening slot  (e.g. P4)
      //   Evening overflow → unlock last  morning slot  (e.g. P3)
      // Normal H1/H2/H3 clash detection still prevents teacher/room/class
      // conflicts at that boundary slot.
      Map<String, Set<String>> effectiveShiftAllowed =
          Map<String, Set<String>>.from(
            shiftClassAllowed.map((k, v) => MapEntry(k, Set<String>.from(v))));

      if (effectiveShiftAllowed.isNotEmpty) {
        // Helper: parse "HH:MM" → minutes since midnight
        int parseMin(String t) {
          final p = t.split(':');
          if (p.length < 2) return 0;
          return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
        }

        // Categorise bachelor slots into morning (<11:00) and evening (≥11:00)
        const kBoundaryMin = 11 * 60; // 11:00 in minutes
        final bachSlots = timeSlots.where((ts) => ts.level.index == 1).toList();

        final morningBachSlots = bachSlots
            .where((ts) => parseMin(ts.startTime) < kBoundaryMin)
            .toList()
          ..sort((a, b) => parseMin(a.startTime).compareTo(parseMin(b.startTime)));

        final eveningBachSlots = bachSlots
            .where((ts) => parseMin(ts.startTime) >= kBoundaryMin)
            .toList()
          ..sort((a, b) => parseMin(a.startTime).compareTo(parseMin(b.startTime)));

        // Shift capacity = slot_count × workingDays
        final morningCapacity = morningBachSlots.length * workingDays;
        final eveningCapacity = eveningBachSlots.length * workingDays;

        // Total credit hours already assigned per class
        final crHrsByClass = <String, int>{};
        for (final a in assignments) {
          crHrsByClass[a.classModel.id] =
              (crHrsByClass[a.classModel.id] ?? 0) + a.course.creditHours;
        }

        final mornIds = morningBachSlots.map((s) => s.id).toSet();
        final evenIds = eveningBachSlots.map((s) => s.id).toSet();

        for (final classId in effectiveShiftAllowed.keys.toList()) {
          final allowed     = effectiveShiftAllowed[classId]!;
          final totalCrHrs  = crHrsByClass[classId] ?? 0;

          // Determine which shift this class currently sits in
          final inMorning = allowed.any((id) => mornIds.contains(id));
          final inEvening = allowed.any((id) => evenIds.contains(id));

          if (inMorning && !inEvening) {
            // Morning-shift class: overflow spills into the first evening slot
            if (totalCrHrs > morningCapacity && eveningBachSlots.isNotEmpty) {
              allowed.add(eveningBachSlots.first.id);
            }
          } else if (inEvening && !inMorning) {
            // Evening-shift class: overflow spills into the last morning slot
            if (totalCrHrs > eveningCapacity && morningBachSlots.isNotEmpty) {
              allowed.add(morningBachSlots.last.id);
            }
          }
        }
      }

      // ── 4. Shift slot blocks ─────────────────────────────────────────────
      // For each class that has a shift assignment, build a map of
      // "allowed" slot IDs. The GA treats slots NOT in this set as blocked.
      // We invert: classId → set of BLOCKED slot IDs = all bachelor slots - allowed.
      // Uses effectiveShiftAllowed (which already includes any overflow boundary slot).
      final Map<String, List<String>> shiftClassBlocks = {};
      if (effectiveShiftAllowed.isNotEmpty) {
        // Collect all bachelor slot IDs
        final allBachSlotIds = timeSlots
            .where((ts) => ts.level.index == 1) // bachelors index
            .map((ts) => ts.id)
            .toSet();
        for (final entry in effectiveShiftAllowed.entries) {
          final classId = entry.key;
          final allowed = entry.value;
          // Block = all bachelor slots that are NOT in allowed
          final blocked = allBachSlotIds.difference(allowed).toList();
          if (blocked.isNotEmpty) shiftClassBlocks[classId] = blocked;
        }
      }

      // ── 5. Run GA in background isolate ───────────────────────────────────
      final lockedSlotsJson = timeSlotLocks.map((l) => l.toJson()).cast<Map<String, dynamic>>().toList();

      final gaInput = GaInput(
        assignments:           assignmentMaps,
        timeSlotIdsByLevel:    tsIdsByLevel,
        timeSlotIntervals:     tsIntervals,
        roomIds:               roomIds,
        lockedSlots:           lockedSlotsJson,
        workingDays:           workingDays,
        populationSize:        populationSize,
        maxGenerations:        maxGenerations,
        stagnationLimit:       stagnationLimit,
        electiveClassBlocks:   electiveClassBlocks.map((k, v) => MapEntry(k, v.toList())),
        electiveTeacherBlocks: electiveTeacherBlocks.map((k, v) => MapEntry(k, v.toList())),
        electiveOccupancy:     electiveOccupancy,
        shiftClassBlocks:      shiftClassBlocks,
      );

      // ── CSP-first: guaranteed clash-free (or a precise reason) instead of
      // the GA's stochastic, sometimes-stuck search. Only if the CSP proves
      // the schedule infeasible as given do we fall back to the GA's
      // best-effort search, so a genuinely over-constrained schedule still
      // produces *something* instead of nothing.
      final cspRun = CspScheduler.runCancelable(gaInput);
      _activeCancel = cspRun.cancel;
      GaOutput output;
      try {
        output = await cspRun.result;
      } on GaCancelled {
        return; // status/notify already handled by cancelGA()
      }
      if (_cancelRequested) return;

      if (output.chromosome.isEmpty) {
        String cspMessage = output.message;
        final fIdx = output.failureAssignmentIdx;
        if (fIdx != null && fIdx >= 0 && fIdx < origIndicesMapping.length) {
          final origIdx = origIndicesMapping[fIdx].first;
          if (origIdx >= 0 && origIdx < assignments.length) {
            final a = assignments[origIdx];
            cspMessage = 'No legal day/slot left for ${a.course.name} '
                '(${a.classModel.shortCode}, teacher ${a.teacher.name}) — '
                'every remaining option conflicts with an existing lock or another assignment.';
          }
        }
        final gaRun = GaEngine.runCancelable(gaInput);
        _activeCancel = gaRun.cancel;
        GaOutput gaOutput;
        try {
          gaOutput = await gaRun.result;
        } on GaCancelled {
          return;
        }
        if (_cancelRequested) return;
        output = gaOutput.hardClashes > 0
            ? GaOutput(
                chromosome:     gaOutput.chromosome,
                score:          gaOutput.score,
                hardClashes:    gaOutput.hardClashes,
                generationsRun: gaOutput.generationsRun,
                message:        '$cspMessage\nBest-effort fallback: ${gaOutput.message}',
                breakdown:      gaOutput.breakdown,
              )
            : gaOutput;
      }
      _activeCancel = null;

      // ── 5b. Partial-apply: isolate which independent parts of the schedule
      // are actually clash-free, instead of an all-or-nothing gate. Two
      // assignments can only ever clash via a shared teacher or a shared
      // class+section (the same predicate countClashesMap uses for H1/H3) —
      // so group assignments into clusters by that predicate, then any
      // cluster with zero clashing genes is safe to write regardless of
      // what's still stuck elsewhere. Rooms are excluded from clustering
      // deliberately: GA/CSP never move a room (locked_room_id is always a
      // passthrough), so a gene's room is identical whether it ends up
      // "applied" (chromosome position) or left at its original position —
      // partial application can never create a new room clash either.
      final n = gaInput.assignments.length;
      final clashedIdx = <int>{};
      if (output.chromosome.isNotEmpty) {
        countClashesMap(output.chromosome, gaInput.assignments,
            gaInput.timeSlotIntervals, workingDays,
            electiveOccupancy: gaInput.electiveOccupancy,
            clashedGeneIndices: clashedIdx);
      }
      final clusterParent = List<int>.generate(n, (i) => i);
      int findCluster(int x) {
        while (clusterParent[x] != x) {
          clusterParent[x] = clusterParent[clusterParent[x]];
          x = clusterParent[x];
        }
        return x;
      }
      void unionCluster(int a, int b) {
        final ra = findCluster(a), rb = findCluster(b);
        if (ra != rb) clusterParent[ra] = rb;
      }
      bool shareTeacherOrSection(int i, int j) {
        final ai = gaInput.assignments[i], aj = gaInput.assignments[j];
        final ti = ai['teacher_id']?.toString() ?? '';
        final tj = aj['teacher_id']?.toString() ?? '';
        if (ti.isNotEmpty && ti == tj) return true;
        final sameSection = ai['discipline_id'] == aj['discipline_id'] &&
            ai['section']       == aj['section'] &&
            ai['course_id']     != aj['course_id'];
        if (!sameSection) return false;
        final egA = ai['elective_group_id']?.toString() ?? '';
        if (ai['is_elective'] == true && aj['is_elective'] == true &&
            egA.isNotEmpty && egA == aj['elective_group_id']) {
          return false;
        }
        // Bachelor-only: two different courses, two different teachers, same
        // class/section, same time — an allowed parallel session, not a clash.
        if (ai['level'] == 1 && aj['level'] == 1 && ti != tj) {
          return false;
        }
        return true;
      }
      for (int i = 0; i < n; i++) {
        for (int j = i + 1; j < n; j++) {
          if (shareTeacherOrSection(i, j)) unionCluster(i, j);
        }
      }
      final stuckClusters = clashedIdx.map(findCluster).toSet();
      final safeChromosome = output.chromosome
          .where((g) => !stuckClusters.contains(findCluster(g['assignment_idx'] as int)))
          .toList();
      final stuckCount = n - safeChromosome.length;

      // ── 6. Convert chromosome → Flutter Assignment objects ────────────────────
      final gaAssignments = _chromosomeToAssignments(
        chromosome: output.chromosome,
        originals:  assignments,
        timeSlots:  timeSlots,
        origIndicesMapping: origIndicesMapping,
      );
      final safeGaAssignments = _chromosomeToAssignments(
        chromosome: safeChromosome,
        originals:  assignments,
        timeSlots:  timeSlots,
        origIndicesMapping: origIndicesMapping,
      );

      // ── 7. Push into schedule & notify ────────────────────────────────────
      // Every cluster in safeChromosome is independently verified clash-free
      // (see 5b) — those get written. Anything still stuck stays exactly
      // where it was; it's surfaced via output.message/breakdown, never
      // silently applied.
      final applyToData = safeGaAssignments.isNotEmpty;
      // Detect pinned-vs-pinned clashes before building the result.
      // This is purely diagnostic — it never changes any assignment.
      final pinnedClashMessages = _detectPinnedClashes(
          assignments, timeSlots, workingDays);

      _lastResult = GaScheduleResult(
        message: output.hardClashes == 0 || dataVm == null
            ? output.message
            : stuckCount > 0 && applyToData
                ? '${output.message}\n'
                    'Applied to ${safeGaAssignments.length} of $n assignments — '
                    '$stuckCount assignment(s) in a still-unresolved cluster '
                    'were left unchanged.'
                : '${output.message}\n'
                    'NOT applied to your timetable (result still has clashes) — '
                    'preview only. Fix the bottleneck above and re-run.',
        totalClashes:  output.hardClashes,
        generationsRun: output.generationsRun,
        breakdown:     output.breakdown,
        pinnedClashes: pinnedClashMessages,
      );
      _status = GaStatus.done;

      if (gaAssignments.isNotEmpty) {
        allocVm.applyGaSchedule(
          gaAssignments,
          message:     output.message,
          generations: output.generationsRun,
          clashes:     output.hardClashes,
        );
        // Write GA-optimised positions back into the main data so the matrix
        // (which reads dataVm.combinedAssignments) shows the fresh schedule.
        if (applyToData) dataVm?.applyGaResults(safeGaAssignments);
      }
    } catch (e) {
      if (_cancelRequested) return; // don't show an "error" for a deliberate cancel
      _errorMessage = 'Unexpected error: $e';
      _status       = GaStatus.failed;
    } finally {
      _activeCancel = null;
    }

    notifyListeners();
  }

  // ── Convert chromosome genes → Assignment objects ──────────────────────────
  // Each gene in the new engine = ONE full assignment (all credit hours,
  // as a consecutive day block). Maps back to multiple originals if combined.
  static List<Assignment> _chromosomeToAssignments({
    required List<Map<String, dynamic>> chromosome,
    required List<Assignment>           originals,
    required List<TimeSlot>             timeSlots,
    required List<List<int>>            origIndicesMapping,
  }) {
    final tsById = {for (final ts in timeSlots) ts.id: ts};
    final result = <Assignment>[];

    for (final gene in chromosome) {
      final idx = gene['assignment_idx'] as int;
      if (idx < 0 || idx >= origIndicesMapping.length) continue;
      final origIdxList = origIndicesMapping[idx];

      for (final origIdx in origIdxList) {
        if (origIdx < 0 || origIdx >= originals.length) continue;
        final orig     = originals[origIdx];

        final dayBlock = List<int>.from(gene['day_block'] as List);
        final tsId     = gene['time_slot_id'] as String? ?? orig.timeSlotId;

        if (!tsById.containsKey(tsId)) continue;

        dayBlock.sort();

        // Verify consecutive (should always be true from new engine)
        final isConsecutive = dayBlock.length <= 1 ||
            dayBlock.last - dayBlock.first == dayBlock.length - 1;

        result.add(Assignment(
          id:           '${orig.id}_ga_$idx',
          teacher:      orig.teacher,
          course:       orig.course,
          classModel:   orig.classModel,
          startSlot:    dayBlock.isNotEmpty ? dayBlock.first : 1,
          duration:     isConsecutive ? dayBlock.length : dayBlock.length,
          timeSlotId:   tsId,
          customDays:   isConsecutive ? [] : dayBlock,
          // Rooms are manual-only. A combined gene used to stamp its
          // representative's room onto every sibling class here, silently
          // rewriting user-assigned rooms across the timetable.
          roomId:       orig.roomId,
          // Preserve the original lock state instead of unlocking everything —
          // locked assignments already had their position pinned via
          // locked_start_day/locked_time_slot_id fed into the GA, so this
          // doesn't change this run's placement, just keeps the flag correct
          // for whoever reads it afterward.
          autoAssigned: orig.autoAssigned,
        ));
      }
    }
    return result;
  }

  void reset() {
    _status       = GaStatus.idle;
    _lastResult   = null;
    _errorMessage = null;
    notifyListeners();
  }
}