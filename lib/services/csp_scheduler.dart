import 'package:flutter/foundation.dart';
import 'ga_engine.dart';
import 'cancelable_ga_run.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CSP (backtracking + forward checking) day/slot scheduler.
//
// Consumes the exact same GaInput the GA already builds (in
// backend_viewmodel.dart) and produces the exact same GaOutput shape, so it
// is a drop-in alternative front-end — zero changes needed to the extensive
// block/lock-building logic already in backend_viewmodel.dart.
//
// Unlike the GA, this either returns a chromosome with zero hard clashes
// (guaranteed by construction — not just observed) or an empty chromosome
// with a precise reason naming the exact assignment that ran out of legal
// placements. Rooms are never searched — GaInput's locked_room_id is a pure
// passthrough, matching the app's manual-only room design.
// ─────────────────────────────────────────────────────────────────────────────

class CspScheduler {
  static Future<GaOutput> run(GaInput input) => compute(_runCsp, input);

  /// Same computation, but cancellable — call the returned `cancel` to kill
  /// the worker isolate mid-run instead of waiting for `result`.
  static ({Future<GaOutput> result, void Function() cancel}) runCancelable(GaInput input) {
    final r = CancelableGaRun();
    return (result: r.run(_runCsp, input), cancel: r.cancel);
  }
}

const _emptyBreakdown = {
  'H1_teacher_clash': 0, 'H2_room_clash': 0, 'H3_section_clash': 0,
  'S1_late_period': 0, 'S2_class_gap': 0, 'total_hard': 0, 'total_soft': 0,
};

GaOutput _runCsp(GaInput input) {
  final n = input.assignments.length;
  if (n == 0) {
    return const GaOutput(
      chromosome: [], score: 0, hardClashes: 0, generationsRun: 0,
      message: 'No assignments to schedule.',
      breakdown: _emptyBreakdown,
    );
  }

  final wDays = input.workingDays.clamp(5, 7);

  // ── Master slot index table (mirrors ga_engine.dart's _runGA) ───────────────
  final slotsByLevel = input.timeSlotIdsByLevel;
  final allSlotIds = <String>[];
  final slotIdToIdx = <String, int>{};
  for (final slots in slotsByLevel.values) {
    for (final s in slots) {
      if (!slotIdToIdx.containsKey(s)) {
        slotIdToIdx[s] = allSlotIds.length;
        allSlotIds.add(s);
      }
    }
  }
  if (allSlotIds.isEmpty) allSlotIds.add('DEFAULT');

  // ── Per-assignment metadata (identical derivation to _runGA) ─────────────────
  final creditHours = List<int>.generate(n,
      (i) => ((input.assignments[i]['credit_hours'] as int?) ?? 3).clamp(1, wDays));
  final maxStarts = List<int>.generate(n,
      (i) => (wDays - creditHours[i] + 1).clamp(1, wDays));
  final customDays = List<List<int>>.generate(n, (i) {
    final d = input.assignments[i]['custom_days'];
    if (d is List) return d.map((e) => (e as num).toInt()).toList();
    return const [];
  });
  final teacherIds = List<String>.generate(n,
      (i) => input.assignments[i]['teacher_id']?.toString() ?? '');
  final disciplineIds = List<String>.generate(n,
      (i) => input.assignments[i]['discipline_id']?.toString() ?? '');
  final sectionIds = List<String>.generate(n,
      (i) => input.assignments[i]['section']?.toString() ?? '');
  final courseIds = List<String>.generate(n,
      (i) => input.assignments[i]['course_id']?.toString() ?? '');
  final levels = List<String>.generate(n,
      (i) => input.assignments[i]['level']?.toString() ?? '');
  final isElective = List<bool>.generate(n, (i) => input.assignments[i]['is_elective'] == true);
  final electiveGroupIds = List<String>.generate(n,
      (i) => input.assignments[i]['elective_group_id']?.toString() ?? '');

  List<int> occupiedDays(int i, int startDay) {
    final cd = customDays[i];
    if (cd.isNotEmpty) return cd;
    return List<int>.generate(creditHours[i], (k) => (startDay + k).clamp(1, wDays));
  }

  // ── Elective / shift block sets → slot-index sets (identical to _runGA) ─────
  final classBlockedSlots = <String, Set<int>>{};
  for (final entry in input.electiveClassBlocks.entries) {
    classBlockedSlots[entry.key] =
        entry.value.map((id) => slotIdToIdx[id] ?? -1).where((idx) => idx >= 0).toSet();
  }
  final teacherBlockedSlots = <String, Set<int>>{};
  for (final entry in input.electiveTeacherBlocks.entries) {
    teacherBlockedSlots[entry.key] =
        entry.value.map((id) => slotIdToIdx[id] ?? -1).where((idx) => idx >= 0).toSet();
  }
  final shiftBlockedSlots = <String, Set<int>>{};
  for (final entry in input.shiftClassBlocks.entries) {
    shiftBlockedSlots[entry.key] =
        entry.value.map((id) => slotIdToIdx[id] ?? -1).where((idx) => idx >= 0).toSet();
  }

  final validSlotIdxs = List<List<int>>.generate(n, (i) {
    final lvl = levels[i];
    final ids = slotsByLevel[lvl];
    if (ids == null || ids.isEmpty) return [0];
    final allForLevel = ids.map((s) => slotIdToIdx[s] ?? 0).toList();
    final classBlocked = classBlockedSlots[disciplineIds[i]];
    final teacherBlocked = teacherBlockedSlots[teacherIds[i]];
    final shiftBlocked = shiftBlockedSlots[disciplineIds[i]];
    if ((classBlocked == null || classBlocked.isEmpty) &&
        (teacherBlocked == null || teacherBlocked.isEmpty) &&
        (shiftBlocked == null || shiftBlocked.isEmpty)) {
      return allForLevel;
    }
    final filtered = allForLevel.where((s) {
      if (classBlocked != null && classBlocked.contains(s)) return false;
      if (teacherBlocked != null && teacherBlocked.contains(s)) return false;
      if (shiftBlocked != null && shiftBlocked.contains(s)) return false;
      return true;
    }).toList();
    // No silent un-blocking: if every slot is blocked the domain stays empty
    // and the CSP reports the assignment as infeasible by name, instead of
    // masking a data misconfiguration by ignoring the blocks.
    return filtered;
  });

  // ── Locks (identical priority to _runGA: explicit TimeSlotLock, then the
  // assignment's own manual lock) ──────────────────────────────────────────────
  final lockedSlotIdx = List<int>.generate(n, (i) {
    final a = input.assignments[i];
    for (final l in input.lockedSlots) {
      if (l['courseId'] == a['course_id'] && l['level'] == a['level']) {
        if (l['classId'] == null || l['classId'] == a['discipline_id']) {
          final ts = l['timeSlotId'] as String;
          return slotIdToIdx[ts] ?? -1;
        }
      }
    }
    final lockedTs = a['locked_time_slot_id'] as String?;
    if (lockedTs != null && lockedTs.isNotEmpty) {
      return slotIdToIdx[lockedTs] ?? -1;
    }
    return -1;
  });

  final lockedStartDay = List<int>.generate(n, (i) {
    final d = input.assignments[i]['locked_start_day'];
    if (d is int && d >= 1) return d;
    return -1;
  });

  // Rooms are never searched — pure passthrough, matching the GA's
  // manual-only room handling.
  final roomList = input.roomIds.isNotEmpty ? input.roomIds : [null];
  final lockedRoomIdx = List<int>.generate(n, (i) {
    final lockedRm = input.assignments[i]['locked_room_id'] as String?;
    if (lockedRm != null && lockedRm.isNotEmpty) {
      return input.roomIds.indexOf(lockedRm);
    }
    return -1;
  });

  // ── Elective phantom occupancy → direct, unconditional domain removal ───────
  // (Cleaner for a CSP than the GA's fitness-penalty approach: an elective
  // permanently owns that cell for the listed classes/teachers, every day.)
  final numSlotsAll = allSlotIds.length;
  final phantomClassByCell = <int, List<Set<String>>>{};
  final phantomTeacherByCell = <int, List<Set<String>>>{};
  for (final occ in input.electiveOccupancy) {
    final sIdx = slotIdToIdx[occ['slot_id']?.toString() ?? ''] ?? -1;
    if (sIdx < 0) continue;
    final clsIds = ((occ['class_ids'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final tchIds = ((occ['teacher_ids'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final days = ((occ['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    final useDays = days.isEmpty ? List<int>.generate(wDays, (d) => d + 1) : days;
    for (final day in useDays) {
      if (day < 1 || day > wDays) continue;
      final key = day * numSlotsAll + sIdx;
      phantomClassByCell.putIfAbsent(key, () => []).add(clsIds);
      phantomTeacherByCell.putIfAbsent(key, () => []).add(tchIds);
    }
  }
  bool phantomBlocks(int i, int day, int slotIdx) {
    final key = day * numSlotsAll + slotIdx;
    final pCls = phantomClassByCell[key];
    if (pCls != null) {
      for (final s in pCls) {
        if (s.contains(disciplineIds[i])) return true;
      }
    }
    final pTch = phantomTeacherByCell[key];
    if (pTch != null && teacherIds[i].isNotEmpty) {
      for (final s in pTch) {
        if (s.contains(teacherIds[i])) return true;
      }
    }
    return false;
  }

  // ── Build domains: each candidate value is [startDay, slotIdx] ──────────────
  final domains = List<List<List<int>>>.generate(n, (i) {
    final slotOptions = lockedSlotIdx[i] >= 0 ? [lockedSlotIdx[i]] : validSlotIdxs[i];
    final dayOptions = customDays[i].isNotEmpty
        ? const [0]
        : (lockedStartDay[i] >= 1
            ? [lockedStartDay[i]]
            : List<int>.generate(maxStarts[i], (k) => k + 1));
    final result = <List<int>>[];
    for (final slotIdx in slotOptions) {
      for (final startDay in dayOptions) {
        final days = occupiedDays(i, startDay);
        if (days.any((d) => phantomBlocks(i, d, slotIdx))) continue;
        result.add([startDay, slotIdx]);
      }
    }
    return result;
  });

  int? preFailIdx;
  for (int i = 0; i < n; i++) {
    if (domains[i].isEmpty) {
      preFailIdx = i;
      break;
    }
  }

  // ── Slot clock-overlap matrix ────────────────────────────────────────────────
  // Two DIFFERENT slot ids can still collide in real clock time across levels
  // (an Intermediate 08:00-08:40 period sits inside a Bachelor 08:00-09:00
  // period). The search must prune on real overlap, not slot-index equality,
  // or cross-level teacher/section clashes become invisible to the solver.
  // Slots without interval data only conflict with themselves (same fallback
  // countClashesMap uses).
  final slotOverlap = List<List<bool>>.generate(numSlotsAll, (a) =>
      List<bool>.generate(numSlotsAll, (b) {
        if (a == b) return true;
        final ia = input.timeSlotIntervals[allSlotIds[a]];
        final ib = input.timeSlotIntervals[allSlotIds[b]];
        if (ia == null || ib == null) return false;
        final lo = ia['start']! > ib['start']! ? ia['start']! : ib['start']!;
        final hi = ia['end']! < ib['end']! ? ia['end']! : ib['end']!;
        return lo < hi;
      }));

  // ── Neighbor graph: pairs that MIGHT clash (share teacher, or share
  // discipline+section on different courses, minus the elective-group
  // exception) — identical predicate to _fitnessC / _repairClashes / countClashesMap.
  bool sharesConstraint(int i, int j) {
    if (teacherIds[i] == teacherIds[j] && teacherIds[i].isNotEmpty) return true;
    final sharesSection = disciplineIds[i] == disciplineIds[j] &&
        sectionIds[i] == sectionIds[j] &&
        courseIds[i] != courseIds[j];
    if (!sharesSection) return false;
    if (isElective[i] && isElective[j] &&
        electiveGroupIds[i].isNotEmpty && electiveGroupIds[i] == electiveGroupIds[j]) {
      return false;
    }
    // Bachelor-only: two different courses, two different teachers, same
    // class/section, same time — an allowed parallel session, not a clash.
    if (levels[i] == '1' && levels[j] == '1' && teacherIds[i] != teacherIds[j]) {
      return false;
    }
    return true;
  }

  final neighbors = List<List<int>>.generate(n, (_) => []);
  if (preFailIdx == null) {
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        if (sharesConstraint(i, j)) {
          neighbors[i].add(j);
          neighbors[j].add(i);
        }
      }
    }
  }

  bool daysOverlap(List<int> a, List<int> b) {
    for (final d in a) {
      if (b.contains(d)) return true;
    }
    return false;
  }

  // ── Backtracking search with forward checking ────────────────────────────────
  final curDomain = List<List<List<int>>>.generate(n, (i) => List.of(domains[i]));
  final assignedVal = List<List<int>?>.filled(n, null);
  int backtracks = 0;
  int? failureVarIdx;
  bool timedOut = false;
  final sw = Stopwatch()..start();
  const deadlineMs = 25000;

  bool assignNext(List<int> unassigned) {
    if (sw.elapsedMilliseconds > deadlineMs) {
      timedOut = true;
      return false;
    }
    if (unassigned.isEmpty) return true;

    // MRV + degree + teacher-density tiebreak
    // Pre-compute teacher frequency for the tiebreak (cheap, done once).
    // teacherCount is already available as local closure over teacherIds.
    int bestPos = 0;
    for (int p = 1; p < unassigned.length; p++) {
      final cur = unassigned[p], best = unassigned[bestPos];
      final dc = curDomain[cur].length, db = curDomain[best].length;
      final nc = neighbors[cur].length, nb = neighbors[best].length;
      // Teacher frequency: teachers with more assignments have more conflicts.
      final String tc = teacherIds[cur], tb2 = teacherIds[best];
      int tcFreq = 0, tbFreq = 0;
      for (final tid in teacherIds) {
        if (tid == tc && tc.isNotEmpty) tcFreq++;
        if (tid == tb2 && tb2.isNotEmpty) tbFreq++;
      }
      if (dc < db ||
          (dc == db && nc > nb) ||
          (dc == db && nc == nb && tcFreq > tbFreq)) {
        bestPos = p;
      }
    }
    final v = unassigned[bestPos];
    final rest = List<int>.from(unassigned)..removeAt(bestPos);
    final restSet = rest.toSet();

    // LCV: try the value that eliminates the fewest options for neighbors first.
    //
    // Bachelor values are pattern-ordered BEFORE conflict cost, mirroring the
    // college's official BS timetable layout: a course takes one period for a
    // contiguous day block; two courses tile a period across the week with
    // complementary anchored blocks (e.g. days 1-4 + 5-6); early periods fill
    // before later ones. Preference ordering is safe — forward checking and
    // backtracking still guarantee correctness if the preferred value clashes.
    final isBach = levels[v] == '1';
    final classSlotUsed = <int>{};
    if (isBach) {
      for (int j = 0; j < n; j++) {
        if (j != v && assignedVal[j] != null && disciplineIds[j] == disciplineIds[v]) {
          classSlotUsed.add(assignedVal[j]![1]);
        }
      }
    }
    final candidates = List<List<int>>.from(curDomain[v]);
    candidates.sort((x, y) {
      int cost(List<int> val) {
        final daysV = occupiedDays(v, val[0]);
        int c = 0;
        for (final nb in neighbors[v]) {
          if (!restSet.contains(nb)) continue;
          for (final nv in curDomain[nb]) {
            if (slotOverlap[nv[1]][val[1]] && daysOverlap(daysV, occupiedDays(nb, nv[0]))) c++;
          }
        }
        return c;
      }
      if (isBach) {
        int pref(List<int> val) {
          final days = occupiedDays(v, val[0]);
          final pack = classSlotUsed.contains(val[1]) ? 0 : 1;
          final startMin =
              input.timeSlotIntervals[allSlotIds[val[1]]]?['start'] ?? 9999;
          final anchored = (days.first == 1 || days.last == wDays) ? 0 : 1;
          return pack * 100000000 + startMin * 10000 + anchored * 100 + val[0];
        }
        final p = pref(x).compareTo(pref(y));
        if (p != 0) return p;
      }
      return cost(x).compareTo(cost(y));
    });

    for (final val in candidates) {
      assignedVal[v] = val;
      final daysV = occupiedDays(v, val[0]);
      final trail = <MapEntry<int, List<List<int>>>>[];
      var ok = true;
      for (final nb in neighbors[v]) {
        if (!restSet.contains(nb)) continue;
        final dom = curDomain[nb];
        final kept = <List<int>>[];
        final removed = <List<int>>[];
        for (final nv in dom) {
          final conflict = slotOverlap[nv[1]][val[1]] && daysOverlap(daysV, occupiedDays(nb, nv[0]));
          if (conflict) {
            removed.add(nv);
          } else {
            kept.add(nv);
          }
        }
        if (removed.isNotEmpty) {
          trail.add(MapEntry(nb, removed));
          curDomain[nb] = kept;
          if (kept.isEmpty) {
            failureVarIdx = nb;
            ok = false;
            break;
          }
        }
      }
      if (ok && assignNext(rest)) return true;
      for (final e in trail) {
        curDomain[e.key].addAll(e.value);
      }
      assignedVal[v] = null;
      backtracks++;
      if (sw.elapsedMilliseconds > deadlineMs) {
        timedOut = true;
        return false;
      }
    }
    return false;
  }

  final solved = preFailIdx == null && assignNext(List<int>.generate(n, (i) => i));

  if (solved) {
    final chromosome = List<Map<String, dynamic>>.generate(n, (i) {
      final val = assignedVal[i]!;
      final startDay = val[0];
      final slotIdx = val[1];
      final roomIdx = lockedRoomIdx[i];
      final rm = (roomIdx >= 0 && roomIdx < roomList.length) ? roomList[roomIdx] : null;
      return {
        'assignment_idx': i,
        'start_day': startDay,
        'day_block': occupiedDays(i, startDay),
        'time_slot_id': allSlotIds[slotIdx],
        'room_id': rm,
      };
    });

    final bd = countClashesMap(chromosome, input.assignments, input.timeSlotIntervals, wDays,
        electiveOccupancy: input.electiveOccupancy);
    // Room clashes (H2) are explicitly not CSP's concern — rooms are a pure
    // locked passthrough here (manual-only, per the Room Allocation UI) and
    // are never searched, so a pre-existing room double-booking inherited
    // from the current data must not be treated as a CSP failure. Only
    // teacher (H1) and section (H3) clashes — the two things this search
    // actually controls — determine success.
    final coreHard = bd['H1_teacher_clash']! + bd['H3_section_clash']!;
    if (coreHard == 0) {
      return GaOutput(
        chromosome: chromosome,
        score: 0,
        hardClashes: coreHard,
        generationsRun: backtracks,
        message: 'Clash-free schedule found (CSP, $backtracks backtrack(s)) ✓',
        breakdown: bd,
      );
    }
    // Should never happen if the port above is faithful — treat as
    // infeasible so the caller falls back rather than trusting a chromosome
    // that our own verifier disagrees with.
  }

  final failIdx = preFailIdx ?? failureVarIdx;
  final message = timedOut
      ? 'CSP solver timed out after ${deadlineMs}ms without finding a schedule.'
      : (failIdx != null
          ? 'No legal day/slot left for one of the assignments — every remaining option conflicts with an existing lock or another assignment.'
          : 'No feasible clash-free schedule found.');

  return GaOutput(
    chromosome: const [],
    score: n,
    hardClashes: n,
    generationsRun: backtracks,
    message: message,
    breakdown: _emptyBreakdown,
    failureAssignmentIdx: failIdx,
  );
}
