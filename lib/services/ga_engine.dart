import 'dart:math';
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Input / Output types
// ─────────────────────────────────────────────────────────────────────────────

class GaInput {
  final List<Map<String, dynamic>> assignments;
  final Map<String, List<String>> timeSlotIdsByLevel;
  final Map<String, Map<String, int>> timeSlotIntervals;
  final List<String?> roomIds;
  final List<Map<String, dynamic>> lockedSlots;
  final int workingDays;
  final int populationSize;
  final int maxGenerations;
  final int stagnationLimit;
  // Elective slot blocks: prevents regular assignments from occupying elective slots.
  // classId  → list of slot IDs that class cannot be placed in
  // teacherId → list of slot IDs that teacher cannot be placed in
  final Map<String, List<String>> electiveClassBlocks;
  final Map<String, List<String>> electiveTeacherBlocks;
  // Elective occupancy — phantom entries injected into the fitness grid so any
  // regular assignment that clock-overlaps an elective for the same class or
  // teacher is counted as a HARD clash and eliminated by evolution.
  // Each entry: {'slot_id': String, 'class_ids': List<String>, 'teacher_ids': List<String>, 'days': List<int>}
  final List<Map<String, dynamic>> electiveOccupancy;

  // Shift class blocks: classId → list of slot IDs that class CANNOT use
  // because it is restricted to a different shift (morning vs evening).
  final Map<String, List<String>> shiftClassBlocks;

  const GaInput({
    required this.assignments,
    required this.timeSlotIdsByLevel,
    required this.timeSlotIntervals,
    required this.roomIds,
    this.lockedSlots = const [],
    required this.workingDays,
    required this.populationSize,
    required this.maxGenerations,
    required this.stagnationLimit,
    this.electiveClassBlocks = const {},
    this.electiveTeacherBlocks = const {},
    this.electiveOccupancy = const [],
    this.shiftClassBlocks = const {},
  });
}

class GaOutput {
  final List<Map<String, dynamic>> chromosome;
  final int score;
  final int hardClashes;
  final int generationsRun;
  final String message;
  final Map<String, int> breakdown;
  // Set by CspScheduler on infeasibility: the assignment_idx (index into
  // GaInput.assignments) that ran out of legal domain values, so the caller
  // can look up the original Assignment and build a human-readable reason.
  final int? failureAssignmentIdx;

  const GaOutput({
    required this.chromosome,
    required this.score,
    required this.hardClashes,
    required this.generationsRun,
    required this.message,
    required this.breakdown,
    this.failureAssignmentIdx,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

class GaEngine {
  static Future<GaOutput> run(GaInput input) => compute(_runGA, input);

  // Kept for API compatibility (no longer used internally).
  static List<List<int>> buildDayOptions(int workingDays) =>
      List.generate(workingDays, (i) => [i + 1]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact gene struct — uses parallel arrays instead of Map objects.
// This eliminates the massive allocation cost of Map per gene per generation.
//
// For n assignments, a chromosome is 3 flat Int32Lists:
//   startDays[i]   — first day (1-based)
//   timeSlots[i]   — index into master slot list
//   rooms[i]       — index into master room list
//
// day_block is always [startDay .. startDay+creditHours-1] — computed on demand.
// ─────────────────────────────────────────────────────────────────────────────

class _Chrom {
  final Int32List startDays;  // 1-based start day per assignment
  final Int32List timeSlots;  // index into _slotIds
  final Int32List rooms;      // index into _roomIds

  // Note: startDays defaults to 0 (not 1) — safe because every consumer
  // (_randomChrom, _crossoverC) unconditionally overwrites every index
  // before any read ever occurs.
  _Chrom(int n)
      : startDays = Int32List(n),
        timeSlots = Int32List(n),
        rooms     = Int32List(n);

  _Chrom.from(_Chrom o)
      : startDays = Int32List.fromList(o.startDays),
        timeSlots = Int32List.fromList(o.timeSlots),
        rooms     = Int32List.fromList(o.rooms);
}

// ─────────────────────────────────────────────────────────────────────────────
// Core GA — runs inside the isolate
// ─────────────────────────────────────────────────────────────────────────────

GaOutput _runGA(GaInput input) {
  if (input.assignments.isEmpty) {
    return const GaOutput(
      chromosome: [], score: 0, hardClashes: 0, generationsRun: 0,
      message: 'No assignments to schedule.',
      breakdown: {'H1_teacher_clash': 0, 'H2_room_clash': 0,
        'H3_section_clash': 0, 'total_hard': 0, 'total_soft': 0},
    );
  }

  final rng  = Random();
  final n    = input.assignments.length;
  final wDays = input.workingDays.clamp(5, 7);

  // ── Build master index tables (O(1) lookups instead of string hashing) ──────
  // Slot IDs per level
  final slotsByLevel = input.timeSlotIdsByLevel;
  final allSlotIds   = <String>[];
  final slotIdToIdx  = <String, int>{};
  for (final slots in slotsByLevel.values) {
    for (final s in slots) {
      if (!slotIdToIdx.containsKey(s)) {
        slotIdToIdx[s] = allSlotIds.length;
        allSlotIds.add(s);
      }
    }
  }
  if (allSlotIds.isEmpty) allSlotIds.add('DEFAULT');

  // Room indices
  final roomList = input.roomIds.isNotEmpty ? input.roomIds : [null];
  final roomCount = roomList.length;

  // Per-assignment metadata (pre-computed, never changes)
  final creditHours = List<int>.generate(n,
          (i) => ((input.assignments[i]['credit_hours'] as int?) ?? 3).clamp(1, wDays));
  final maxStarts   = List<int>.generate(n,
          (i) => (wDays - creditHours[i] + 1).clamp(1, wDays));
  final customDays = List<List<int>>.generate(n, (i) {
    final d = input.assignments[i]['custom_days'];
    if (d is List) return d.map((e) => (e as num).toInt()).toList();
    return const [];
  });
  final teacherIds  = List<String>.generate(n,
          (i) => input.assignments[i]['teacher_id']?.toString() ?? '');
  final disciplineIds = List<String>.generate(n,
          (i) => input.assignments[i]['discipline_id']?.toString() ?? '');
  final sectionIds  = List<String>.generate(n,
          (i) => input.assignments[i]['section']?.toString() ?? '');
  final courseIds   = List<String>.generate(n,
          (i) => input.assignments[i]['course_id']?.toString() ?? '');
  final levels      = List<String>.generate(n,
          (i) => input.assignments[i]['level']?.toString() ?? '');

  // Build blocked slot index sets from elective allocations.
  // Classes and teachers that appear in elective groups must not have
  // regular assignments placed in those same time slots.
  final classBlockedSlots = <String, Set<int>>{};
  for (final entry in input.electiveClassBlocks.entries) {
    classBlockedSlots[entry.key] = entry.value
        .map((id) => slotIdToIdx[id] ?? -1)
        .where((idx) => idx >= 0)
        .toSet();
  }
  final teacherBlockedSlots = <String, Set<int>>{};
  for (final entry in input.electiveTeacherBlocks.entries) {
    teacherBlockedSlots[entry.key] = entry.value
        .map((id) => slotIdToIdx[id] ?? -1)
        .where((idx) => idx >= 0)
        .toSet();
  }

  // Shift class blocks: classId → set of blocked slot indices
  final shiftBlockedSlots = <String, Set<int>>{};
  for (final entry in input.shiftClassBlocks.entries) {
    shiftBlockedSlots[entry.key] = entry.value
        .map((id) => slotIdToIdx[id] ?? -1)
        .where((idx) => idx >= 0)
        .toSet();
  }

  // Valid slot indices per assignment (filtered by level + elective blocks + shift blocks).
  // If filtering removes every option (edge case), fall back to unfiltered.
  final validSlotIdxs = List<List<int>>.generate(n, (i) {
    final lvl   = levels[i];
    final ids   = slotsByLevel[lvl];
    if (ids == null || ids.isEmpty) return [0];
    final allForLevel = ids.map((s) => slotIdToIdx[s] ?? 0).toList();

    final classBlocked   = classBlockedSlots[disciplineIds[i]];
    final teacherBlocked = teacherBlockedSlots[teacherIds[i]];
    final shiftBlocked   = shiftBlockedSlots[disciplineIds[i]];
    if ((classBlocked == null || classBlocked.isEmpty) &&
        (teacherBlocked == null || teacherBlocked.isEmpty) &&
        (shiftBlocked == null || shiftBlocked.isEmpty)) {
      return allForLevel;
    }
    final filtered = allForLevel.where((s) {
      if (classBlocked != null   && classBlocked.contains(s))   return false;
      if (teacherBlocked != null && teacherBlocked.contains(s)) return false;
      if (shiftBlocked != null   && shiftBlocked.contains(s))   return false;
      return true;
    }).toList();
    return filtered.isEmpty ? allForLevel : filtered;
  });

  // Locked slot index per assignment (-1 = not locked)
  // Priority: explicit TimeSlotLock first, then assignment's own locked_time_slot_id
  final lockedSlotIdx = List<int>.generate(n, (i) {
    final a = input.assignments[i];
    // Check explicit locks first
    for (final l in input.lockedSlots) {
      if (l['courseId'] == a['course_id'] && l['level'] == a['level']) {
        if (l['classId'] == null || l['classId'] == a['discipline_id']) {
          final ts = l['timeSlotId'] as String;
          return slotIdToIdx[ts] ?? -1;
        }
      }
    }
    // Check if assignment itself has a manually locked time slot
    final lockedTs = a['locked_time_slot_id'] as String?;
    if (lockedTs != null && lockedTs.isNotEmpty) {
      return slotIdToIdx[lockedTs] ?? -1;
    }
    return -1;
  });

  final lockedRoomIdx = List<int>.generate(n, (i) {
    final a = input.assignments[i];
    final lockedRm = a['locked_room_id'] as String?;
    if (lockedRm != null && lockedRm.isNotEmpty) {
      return input.roomIds.indexOf(lockedRm);
    }
    return -1;
  });

  final isElective = List<bool>.generate(n, (i) => input.assignments[i]['is_elective'] == true);

  // ── Phantom elective occupancy for fitness ─────────────────────────────────
  // Electives are NOT genes, but they permanently occupy (day, slot) cells.
  // We pre-compute their occupancy so fitness can count clashes against them.
  // phantomBySlotDay[key] where key = day * numSlotsAll + slotIdx
  //   → list of (classIdsSet, teacherIdsSet) tuples occupying that cell
  final phantomClassSets   = <int, List<Set<String>>>{};
  final phantomTeacherSets = <int, List<Set<String>>>{};
  final numSlotsAll = allSlotIds.length;
  for (final occ in input.electiveOccupancy) {
    final slotId  = occ['slot_id']?.toString() ?? '';
    final sIdx    = slotIdToIdx[slotId] ?? -1;
    if (sIdx < 0) continue;
    final clsIds  = ((occ['class_ids']   as List?) ?? const []).map((e) => e.toString()).toSet();
    final tchIds  = ((occ['teacher_ids'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final days    = ((occ['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    final useDays = days.isEmpty ? List<int>.generate(wDays, (d) => d + 1) : days;
    for (final day in useDays) {
      if (day < 1 || day > wDays) continue;
      final key = day * numSlotsAll + sIdx;
      phantomClassSets.putIfAbsent(key, () => []).add(clsIds);
      phantomTeacherSets.putIfAbsent(key, () => []).add(tchIds);
    }
  }
  final electiveGroupIds = List<String>.generate(n, (i) => input.assignments[i]['elective_group_id']?.toString() ?? '');

  // Locked start day per assignment (-1 = not locked, GA can choose freely)
  // When an assignment has autoAssigned=false, its startSlot is manually set.
  final lockedStartDay = List<int>.generate(n, (i) {
    final a = input.assignments[i];
    final d = a['locked_start_day'];
    if (d is int && d >= 1) return d;
    return -1;
  });

  // Slot start/end minutes for overlap detection
  final slotStart = List<int>.generate(allSlotIds.length, (i) {
    final ts = allSlotIds[i];
    return input.timeSlotIntervals[ts]?['start'] ?? 0;
  });
  final slotEnd = List<int>.generate(allSlotIds.length, (i) {
    final ts = allSlotIds[i];
    return input.timeSlotIntervals[ts]?['end'] ?? 0;
  });

  // Per-assignment earliest allowed slot start (minutes) — the S1 "prefer
  // early periods" soft score anchors to what's actually available for THIS
  // level/shift, not a hardcoded clock time. A global 8am anchor would push
  // every Bachelor course toward periods a later-starting shift never uses.
  final earliestAllowedStart = List<int>.generate(n, (i) {
    var best = 1 << 30;
    for (final s in validSlotIdxs[i]) {
      if (slotStart[s] < best) best = slotStart[s];
    }
    return best == 1 << 30 ? 480 : best;
  });

  // ── Slot clock-overlap adjacency ────────────────────────────────────────────
  // CRITICAL for cross-level clash detection: a Bachelor 08:00-09:00 slot
  // clock-overlaps Intermediate 08:00-08:40 AND 08:40-09:20 even though they
  // are different slot indices. The fitness grid is keyed by (day, slotIdx),
  // so clashes between DIFFERENT indices are invisible unless we explicitly
  // scan every clock-overlapping bucket pair. overlapAdj[a] lists every slot
  // index b >= a whose real clock interval intersects a's (including a itself)
  // — the ">= a" half keeps pair scanning symmetric without double counting.
  // Slots without interval data overlap only themselves (same fallback as CSP).
  final overlapAdj = List<List<int>>.generate(allSlotIds.length, (a) {
    final out = <int>[a];
    final aS = slotStart[a], aE = slotEnd[a];
    if (aE <= 0) return out; // no interval data → self only
    for (int b = a + 1; b < allSlotIds.length; b++) {
      final bS = slotStart[b], bE = slotEnd[b];
      if (bE <= 0) continue;
      final lo = aS > bS ? aS : bS;
      final hi = aE < bE ? aE : bE;
      if (lo < hi) out.add(b); // real clock overlap
    }
    return out;
  });

  // ── Population ──────────────────────────────────────────────────────────────
  // Use a much smaller adaptive population.
  // Effective rule: pop = min(200, max(30, n * 3))
  final effectivePop = input.populationSize.clamp(
      n < 20 ? 30 : 50,
      n > 200 ? 200 : input.populationSize);

  // ── Build a greedy clash-free seed chromosome ───────────────────────────────
  // For each gene (processed in a shuffled order so no gene is systematically
  // favoured), try every (slotIdx, startDay) combo and accept the first one
  // that is clash-free against all already-placed genes. Locked genes are
  // placed first. Genes with no clash-free option fall back to a random pick.
  _Chrom greedySeed() {
    final c = _Chrom(n);
    // Start with all locked values first.
    for (int i = 0; i < n; i++) {
      final lDay  = lockedStartDay[i];
      final lSlot = lockedSlotIdx[i];
      final lRoom = lockedRoomIdx[i];
      c.startDays[i] = lDay  >= 1 ? lDay  : 1;
      c.timeSlots[i] = lSlot >= 0 ? lSlot : validSlotIdxs[i].first;
      c.rooms[i]     = (lRoom >= 0 && lRoom < roomCount) ? lRoom : 0;
    }
    // Process in shuffled order so no gene is privileged.
    final order = List<int>.generate(n, (i) => i)..shuffle(rng);
    // Helper: check if gene i at (sd, ts) clashes with any already-committed gene.
    bool localClash(int i, int sd, int ts) {
      final iStart = slotStart[ts], iEnd = slotEnd[ts];
      for (int j = 0; j < n; j++) {
        if (j == i) continue;
        // Skip if gene j hasn't been placed yet (still on its default first-slot)
        // — only check genes that appear BEFORE i in the order list.
        if (order.indexOf(j) > order.indexOf(i)) continue;
        // Teacher or section conflict?
        bool conflict = false;
        if (teacherIds[i].isNotEmpty && teacherIds[i] == teacherIds[j]) conflict = true;
        if (!conflict) {
          if (disciplineIds[i] == disciplineIds[j] &&
              sectionIds[i]    == sectionIds[j]    &&
              courseIds[i]     != courseIds[j]) {
            final sameEG = isElective[i] && isElective[j] &&
                electiveGroupIds[i] == electiveGroupIds[j];
            if (!sameEG) conflict = true;
          }
        }
        if (!conflict && (c.rooms[i] == 0 || c.rooms[j] != c.rooms[i])) continue;
        // Clock overlap?
        final jSlot = c.timeSlots[j];
        final jStart = slotStart[jSlot], jEnd = slotEnd[jSlot];
        bool clockOv;
        if (iEnd > 0 && jEnd > 0) {
          clockOv = (iStart < jEnd) && (jStart < iEnd);
        } else {
          clockOv = ts == jSlot;
        }
        if (!clockOv) continue;
        // Day overlap?
        final iDays = customDays[i].isNotEmpty
            ? customDays[i]
            : List.generate(creditHours[i], (k) => (sd + k).clamp(1, wDays));
        final jDay = c.startDays[j];
        final jDays = customDays[j].isNotEmpty
            ? customDays[j]
            : List.generate(creditHours[j], (k) => (jDay + k).clamp(1, wDays));
        bool dayOv = false;
        for (final d in iDays) { if (jDays.contains(d)) { dayOv = true; break; } }
        if (!dayOv) continue;
        if (conflict) return true;
        if (c.rooms[i] != 0 && c.rooms[j] == c.rooms[i]) return true;
      }
      return false;
    }

    for (final i in order) {
      if (lockedSlotIdx[i] >= 0 && lockedStartDay[i] >= 1) continue; // fully locked
      final slots = lockedSlotIdx[i] >= 0
          ? [lockedSlotIdx[i]]
          : validSlotIdxs[i];
      final maxSd = maxStarts[i];
      bool placed = false;
      // Shuffle slot + day options for diversity across seed runs.
      final shuffledSlots = [...slots]..shuffle(rng);
      final shuffledDays  = List.generate(maxSd, (k) => k + 1)..shuffle(rng);
      for (final ts in shuffledSlots) {
        for (final sd in shuffledDays) {
          if (lockedStartDay[i] >= 1 && sd != lockedStartDay[i]) continue;
          c.timeSlots[i] = ts;
          c.startDays[i] = sd;
          if (!localClash(i, sd, ts)) { placed = true; break; }
        }
        if (placed) break;
      }
      if (!placed) {
        // Fallback: random placement (better than staying on first-slot default).
        c.timeSlots[i] = slots[rng.nextInt(slots.length)];
        if (lockedStartDay[i] < 1) {
          c.startDays[i] = rng.nextInt(maxSd) + 1;
        }
      }
    }
    return c;
  }

  // Seed ~20% of the population with greedy chromosomes for diversity; the rest
  // are fully random to maintain exploration.
  final greedyCount = (effectivePop * 0.20).round().clamp(1, 5);
  var pop = List<_Chrom>.generate(effectivePop, (idx) {
    if (idx < greedyCount) return greedySeed();
    return _randomChrom(n, wDays, maxStarts, validSlotIdxs, roomCount,
        lockedSlotIdx, lockedStartDay, lockedRoomIdx, rng);
  });

  var bestChrom = _Chrom.from(pop.first);
  final scores = List<int>.filled(effectivePop, 0);
  final numSlots = allSlotIds.length;
  final maxGridSize = (wDays + 2) * numSlots;
  final dtGrid = List<List<int>>.generate(maxGridSize, (_) => []);
  // Sparse touched-cell tracking for _fitnessC — reused across every call so
  // the grid clear/scan cost is O(cells occupied), not O(maxGridSize).
  final touchedFlag = Uint8List(maxGridSize);
  final touchedKeys = <int>[];

  var bestScore = _fitnessC(pop.first, n, wDays, lockedStartDay, lockedSlotIdx, lockedRoomIdx,
      disciplineIds, sectionIds, courseIds, maxStarts, slotStart, slotEnd, creditHours, teacherIds, isElective, electiveGroupIds, dtGrid, numSlots,
      phantomClassSets, phantomTeacherSets, customDays, touchedFlag, touchedKeys, overlapAdj, earliestAllowedStart);

  int gensRun    = 0;
  int stagnation = 0;
  int genSinceImprovement = 0;
  double mutRate = 0.15;
  final elites   = (effectivePop * 0.10).round().clamp(2, 15);
  // Scores carried forward for cloned elites (index-aligned with nextPop's
  // elite slots) — avoids re-running _fitnessC on chromosomes that are
  // byte-identical to ones already scored last generation.
  final eliteScores = List<int>.filled(elites, 0);

  // Pre-allocate score array — reuse each generation to avoid GC pressure

  // ── Main loop ──────────────────────────────────────────────────────────────
  final maxGen = input.maxGenerations;
  // ponytail: flat 60s wall-clock cap (returns best-so-far); make it a
  // GaInput field if some dataset genuinely needs longer.
  final wallClock = Stopwatch()..start();
  for (int gen = 0; gen < maxGen; gen++) {
    if (gen > 0 && wallClock.elapsedMilliseconds > 60000) break;
    gensRun = gen + 1;

    // Evaluate population. From generation 1 onward, indices [0, elites) are
    // clones carried over unchanged from the previous generation's elites —
    // their score was already recorded in eliteScores, so only the
    // freshly-bred children [elites, effectivePop) need re-evaluating.
    final evalFrom = gen == 0 ? 0 : elites;
    if (gen > 0) {
      for (int i = 0; i < elites; i++) {
        scores[i] = eliteScores[i];
      }
    }
    for (int i = evalFrom; i < effectivePop; i++) {
      scores[i] = _fitnessC(pop[i], n, wDays, lockedStartDay, lockedSlotIdx, lockedRoomIdx,
          disciplineIds, sectionIds, courseIds, maxStarts, slotStart, slotEnd, creditHours, teacherIds, isElective, electiveGroupIds, dtGrid, numSlots,
          phantomClassSets, phantomTeacherSets, customDays, touchedFlag, touchedKeys, overlapAdj, earliestAllowedStart);
    }

    // Find best
    int bestIdx = 0;
    for (int i = 1; i < effectivePop; i++) {
      if (scores[i] < scores[bestIdx]) bestIdx = i;
    }

    if (scores[bestIdx] < bestScore) {
      bestScore  = scores[bestIdx];
      bestChrom  = _Chrom.from(pop[bestIdx]);
      stagnation = 0;
      genSinceImprovement = 0;
      mutRate    = 0.15;
    } else {
      stagnation++;
      genSinceImprovement++;
    }

    if (bestScore == 0) break;

    // Give up early only once mutation has already escalated to its max and
    // a further several stagnation windows have passed with zero
    // improvement at that max rate — at that point more generations are
    // extremely unlikely to help (verified: independent runs on the same
    // input converge to the identical bestScore well before maxGenerations,
    // then burn the remaining budget for nothing).
    if (mutRate >= 0.80 && genSinceImprovement >= input.stagnationLimit * 3) break;

    if (stagnation >= input.stagnationLimit) {
      mutRate    = (mutRate * 1.5).clamp(0.15, 0.80);
      stagnation = 0;
    }

    // Sort by score (in-place index sort)
    final ranked = List<int>.generate(effectivePop, (i) => i)
      ..sort((a, b) => scores[a].compareTo(scores[b]));

    final nextPop = <_Chrom>[];

    // Elitism — copy top k directly, carrying their known score forward
    for (int i = 0; i < elites; i++) {
      nextPop.add(_Chrom.from(pop[ranked[i]]));
      eliteScores[i] = scores[ranked[i]];
    }

    // Fill rest with crossover + mutation
    while (nextPop.length < effectivePop) {
      final p1 = _tournament(pop, scores, rng, effectivePop);
      final p2 = _tournament(pop, scores, rng, effectivePop);
      final child = _crossoverC(p1, p2, rng, n);
      _mutateC(child, n, wDays, maxStarts, validSlotIdxs, roomCount,
          lockedSlotIdx, lockedStartDay, lockedRoomIdx, mutRate, rng);
      _repairClashes(child, n, wDays, creditHours, customDays, validSlotIdxs,
          lockedSlotIdx, teacherIds, disciplineIds, sectionIds, courseIds,
          isElective, electiveGroupIds, numSlots, rng,
          dtGrid, touchedFlag, touchedKeys, roomCount, lockedRoomIdx, overlapAdj);
      nextPop.add(child);
    }

    pop = nextPop;
  }

  // ── Deterministic exhaustive sweep ──────────────────────────────────────────
  // Evolution done — now systematically eliminate every remaining resolvable
  // clash. For each gene in a hard clash (cross-level clock-aware), try EVERY
  // legal (startDay × validSlot) combination and accept the first placement
  // that leaves the gene completely clash-free. Repeats until a full pass
  // makes no change. Locked genes are never moved. This converts the GA's
  // "best effort" into CSP-style completeness on the residual clashes.
  {
    bool genesConflict(int gi, int gj) {
      if (teacherIds[gi] == teacherIds[gj] && teacherIds[gi].isNotEmpty) return true;
      if (disciplineIds[gi] == disciplineIds[gj] &&
          sectionIds[gi]    == sectionIds[gj]    &&
          courseIds[gi]     != courseIds[gj]) {
        if (!(isElective[gi] && isElective[gj] &&
              electiveGroupIds[gi] == electiveGroupIds[gj])) {
          return true;
        }
      }
      return false;
    }

    List<int> geneDays(int i, int sd) {
      final cDays = customDays[i];
      if (cDays.isNotEmpty) return cDays;
      return List<int>.generate(creditHours[i], (k) => (sd + k).clamp(1, wDays));
    }

    // Full cross-level clash test of gene i at (sd, ts) against every other
    // gene's CURRENT placement in bestChrom.
    bool placementClashes(int i, int sd, int ts) {
      final daysI = geneDays(i, sd);
      final sI = slotStart[ts], eI = slotEnd[ts];
      for (int j = 0; j < n; j++) {
        if (j == i) continue;
        if (!genesConflict(i, j)) {
          if (bestChrom.rooms[i] == 0 || bestChrom.rooms[j] != bestChrom.rooms[i]) continue;
        }
        final tsJ = bestChrom.timeSlots[j];
        final sJ = slotStart[tsJ], eJ = slotEnd[tsJ];
        bool clockOv;
        if (eI > 0 && eJ > 0) {
          final lo = sI > sJ ? sI : sJ;
          final hi = eI < eJ ? eI : eJ;
          clockOv = lo < hi;
        } else {
          clockOv = ts == tsJ;
        }
        if (!clockOv) continue;
        final daysJ = geneDays(j, bestChrom.startDays[j]);
        bool dayOv = false;
        for (final d in daysI) {
          if (daysJ.contains(d)) { dayOv = true; break; }
        }
        if (!dayOv) continue;
        if (genesConflict(i, j)) return true;
        if (bestChrom.rooms[i] != 0 && bestChrom.rooms[j] == bestChrom.rooms[i]) return true;
      }
      return false;
    }

    // ── Helper: precomputed MRV score for one gene ───────────────────────────
    int candidateCount(int i) {
      final slotLocked = lockedSlotIdx[i] >= 0;
      final dayLocked  = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
      final slotOpts   = slotLocked ? [bestChrom.timeSlots[i]] : validSlotIdxs[i];
      final maxSd      = maxStarts[i];
      final dayOpts    = dayLocked
          ? [bestChrom.startDays[i]]
          : List<int>.generate(maxSd, (k) => k + 1);
      int count = 0;
      for (final ts in slotOpts) {
        for (final sd in dayOpts) {
          if (ts == bestChrom.timeSlots[i] && sd == bestChrom.startDays[i]) continue;
          if (!placementClashes(i, sd, ts)) count++;
        }
      }
      return count;
    }

    // Builds the set of free clashing genes (not fully locked).
    List<int> collectClashingFree() {
      final out = <int>[];
      for (int i = 0; i < n; i++) {
        if (!placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i])) continue;
        final slotLocked = lockedSlotIdx[i] >= 0;
        final dayLocked  = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
        if (slotLocked && dayLocked) continue;
        out.add(i);
      }
      return out;
    }


    // ── Helper: count how many genes conflict with gene i at its current pos ──
    int clashCountFor(int i) {
      int c = 0;
      final sd = bestChrom.startDays[i];
      final ts = bestChrom.timeSlots[i];
      final daysI = geneDays(i, sd);
      final sI = slotStart[ts], eI = slotEnd[ts];
      for (int j = 0; j < n; j++) {
        if (j == i) continue;
        if (!genesConflict(i, j)) {
          if (bestChrom.rooms[i] == 0 || bestChrom.rooms[j] != bestChrom.rooms[i]) continue;
        }
        final tsJ = bestChrom.timeSlots[j];
        final sJ = slotStart[tsJ], eJ = slotEnd[tsJ];
        bool clockOv;
        if (eI > 0 && eJ > 0) {
          final lo = sI > sJ ? sI : sJ;
          final hi = eI < eJ ? eI : eJ;
          clockOv = lo < hi;
        } else {
          clockOv = ts == tsJ;
        }
        if (!clockOv) continue;
        final daysJ = geneDays(j, bestChrom.startDays[j]);
        bool dayOv = false;
        for (final d in daysI) {
          if (daysJ.contains(d)) { dayOv = true; break; }
        }
        if (!dayOv) continue;
        if (genesConflict(i, j)) { c++; continue; }
        if (bestChrom.rooms[i] != 0 && bestChrom.rooms[j] == bestChrom.rooms[i]) c++;
      }
      return c;
    }

    // ── Helper: count clashes for gene i if placed at (sd2, ts2) ─────────────
    int clashCountIfAt(int i, int sd2, int ts2) {
      int c = 0;
      final daysI = geneDays(i, sd2);
      final sI = slotStart[ts2], eI = slotEnd[ts2];
      for (int j = 0; j < n; j++) {
        if (j == i) continue;
        if (!genesConflict(i, j)) {
          if (bestChrom.rooms[i] == 0 || bestChrom.rooms[j] != bestChrom.rooms[i]) continue;
        }
        final tsJ = bestChrom.timeSlots[j];
        final sJ = slotStart[tsJ], eJ = slotEnd[tsJ];
        bool clockOv;
        if (eI > 0 && eJ > 0) {
          final lo = sI > sJ ? sI : sJ;
          final hi = eI < eJ ? eI : eJ;
          clockOv = lo < hi;
        } else {
          clockOv = ts2 == tsJ;
        }
        if (!clockOv) continue;
        final daysJ = geneDays(j, bestChrom.startDays[j]);
        bool dayOv = false;
        for (final d in daysI) {
          if (daysJ.contains(d)) { dayOv = true; break; }
        }
        if (!dayOv) continue;
        if (genesConflict(i, j)) { c++; continue; }
        if (bestChrom.rooms[i] != 0 && bestChrom.rooms[j] == bestChrom.rooms[i]) c++;
      }
      return c;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 1 — MRV-ordered sweep with min-clash fallback (40 passes)
    //
    // First-accept clash-free; if none exists, move to the position that
    // minimises the gene's clash count (even if > 0). This "min-clash fallback"
    // ensures EVERY pass makes measurable progress even in a dense schedule —
    // previously the solver could stall doing nothing when clash-free was out
    // of reach.
    // ─────────────────────────────────────────────────────────────────────────
    const maxSweeps = 40;

    // trySingleMove with min-clash fallback
    bool trySingleMoveFull(int i) {
      if (!placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i])) return false;
      final slotLocked = lockedSlotIdx[i] >= 0;
      final dayLocked  = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
      final slotOpts   = slotLocked ? [bestChrom.timeSlots[i]] : validSlotIdxs[i];
      final maxSd      = maxStarts[i];
      final dayOpts    = dayLocked
          ? [bestChrom.startDays[i]]
          : List<int>.generate(maxSd, (k) => k + 1);

      int bestTs = bestChrom.timeSlots[i];
      int bestSd = bestChrom.startDays[i];
      int bestC  = clashCountFor(i); // current clash count — must beat this

      for (final ts in slotOpts) {
        for (final sd in dayOpts) {
          if (ts == bestChrom.timeSlots[i] && sd == bestChrom.startDays[i]) continue;
          final c = clashCountIfAt(i, sd, ts);
          if (c == 0) {
            // Clash-free: accept immediately
            bestChrom.timeSlots[i] = ts;
            if (!dayLocked) bestChrom.startDays[i] = sd;
            return true;
          }
          if (c < bestC) { bestC = c; bestTs = ts; bestSd = sd; }
        }
      }
      // Min-clash fallback: move to the least-clashing position found
      if (bestTs != bestChrom.timeSlots[i] || bestSd != bestChrom.startDays[i]) {
        bestChrom.timeSlots[i] = bestTs;
        if (!dayLocked) bestChrom.startDays[i] = bestSd;
        return true;
      }
      return false;
    }

    for (int sweep = 0; sweep < maxSweeps; sweep++) {
      final clashingFree = collectClashingFree();
      if (clashingFree.isEmpty) break;
      // MRV: sort by actual clash count descending (worst-offender first) then
      // by candidate count ascending (hardest-to-place next), so the most
      // disruptive gene moves first and frees up space for others.
      final clashCounts = <int, int>{for (final i in clashingFree) i: clashCountFor(i)};
      final mrvScores   = <int, int>{for (final i in clashingFree) i: candidateCount(i)};
      clashingFree.sort((a, b) {
        final cc = clashCounts[b]!.compareTo(clashCounts[a]!); // more conflicts first
        if (cc != 0) return cc;
        return mrvScores[a]!.compareTo(mrvScores[b]!); // fewer candidates first
      });
      bool improved = false;
      for (final i in clashingFree) {
        if (trySingleMoveFull(i)) improved = true;
      }
      if (!improved) break;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 2 — Pairwise swap + 3-way chain moves (20 passes each)
    //
    // Pairwise: swap (slot,day) of i and j — accept when BOTH become clash-free.
    // Chain:    rotate three mutually non-conflicting genes A→B→C→A — accept
    //           when all three become clash-free. Resolves deadlocks that pure
    //           pairwise cannot (e.g. three genes each blocking the other's slot).
    // ─────────────────────────────────────────────────────────────────────────
    {
      const maxSwapPasses = 20;
      for (int sp = 0; sp < maxSwapPasses; sp++) {
        final clashingFree = collectClashingFree();
        if (clashingFree.isEmpty) break;
        bool improved = false;

        for (final i in clashingFree) {
          if (!placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i])) continue;
          if (customDays[i].isNotEmpty) continue;
          final slotLockedI = lockedSlotIdx[i] >= 0;
          final dayLockedI  = lockedStartDay[i] >= 1;
          final tsI = bestChrom.timeSlots[i];
          final sdI = bestChrom.startDays[i];
          bool done = false;

          for (int j = 0; j < n && !done; j++) {
            if (j == i || genesConflict(i, j)) continue;
            if (customDays[j].isNotEmpty) continue;
            final slotLockedJ = lockedSlotIdx[j] >= 0;
            final dayLockedJ  = lockedStartDay[j] >= 1;
            final tsJ = bestChrom.timeSlots[j];
            final sdJ = bestChrom.startDays[j];

            if (slotLockedI  && tsI != tsJ) continue;
            if (slotLockedJ  && tsJ != tsI) continue;
            if (!slotLockedI && !validSlotIdxs[i].contains(tsJ)) continue;
            if (!slotLockedJ && !validSlotIdxs[j].contains(tsI)) continue;

            // Pairwise swap
            bestChrom.timeSlots[i] = tsJ; if (!dayLockedI) bestChrom.startDays[i] = sdJ.clamp(1, maxStarts[i]).toInt();
            bestChrom.timeSlots[j] = tsI; if (!dayLockedJ) bestChrom.startDays[j] = sdI.clamp(1, maxStarts[j]).toInt();

            final iOk = !placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i]);
            final jOk = !placementClashes(j, bestChrom.startDays[j], bestChrom.timeSlots[j]);
            if (iOk && jOk) { improved = true; done = true; continue; }

            // Revert pairwise — try 3-way chain with a third gene k
            bestChrom.timeSlots[i] = tsI; if (!dayLockedI) bestChrom.startDays[i] = sdI;
            bestChrom.timeSlots[j] = tsJ; if (!dayLockedJ) bestChrom.startDays[j] = sdJ;

            // 3-way: i→j's slot, j→k's slot, k→i's slot
            for (int k = 0; k < n && !done; k++) {
              if (k == i || k == j) continue;
              if (genesConflict(i, k) || genesConflict(j, k)) continue;
              if (customDays[k].isNotEmpty) continue;
              final slotLockedK = lockedSlotIdx[k] >= 0;
              final dayLockedK  = lockedStartDay[k] >= 1;
              final tsK = bestChrom.timeSlots[k];
              final sdK = bestChrom.startDays[k];

              // Check domain feasibility for the 3-way rotation i→tsJ, j→tsK, k→tsI
              if (slotLockedI && tsI != tsJ) continue;
              if (slotLockedJ && tsJ != tsK) continue;
              if (slotLockedK && tsK != tsI) continue;
              if (!slotLockedI && !validSlotIdxs[i].contains(tsJ)) continue;
              if (!slotLockedJ && !validSlotIdxs[j].contains(tsK)) continue;
              if (!slotLockedK && !validSlotIdxs[k].contains(tsI)) continue;

              bestChrom.timeSlots[i] = tsJ; if (!dayLockedI) bestChrom.startDays[i] = sdJ.clamp(1, maxStarts[i]).toInt();
              bestChrom.timeSlots[j] = tsK; if (!dayLockedJ) bestChrom.startDays[j] = sdK.clamp(1, maxStarts[j]).toInt();
              bestChrom.timeSlots[k] = tsI; if (!dayLockedK) bestChrom.startDays[k] = sdI.clamp(1, maxStarts[k]).toInt();

              final aOk = !placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i]);
              final bOk = !placementClashes(j, bestChrom.startDays[j], bestChrom.timeSlots[j]);
              final cOk = !placementClashes(k, bestChrom.startDays[k], bestChrom.timeSlots[k]);
              if (aOk && bOk && cOk) { improved = true; done = true; continue; }

              // Revert 3-way
              bestChrom.timeSlots[i] = tsI; if (!dayLockedI) bestChrom.startDays[i] = sdI;
              bestChrom.timeSlots[j] = tsJ; if (!dayLockedJ) bestChrom.startDays[j] = sdJ;
              bestChrom.timeSlots[k] = tsK; if (!dayLockedK) bestChrom.startDays[k] = sdK;
            }
          }
        }
        if (!improved) break;
        // After each swap pass, run a full MRV sweep to exploit freed slots.
        for (int sweep = 0; sweep < 8; sweep++) {
          final cf = collectClashingFree();
          if (cf.isEmpty) break;
          final cc2 = <int, int>{for (final i in cf) i: clashCountFor(i)};
          final mv2 = <int, int>{for (final i in cf) i: candidateCount(i)};
          cf.sort((a, b) {
            final d = cc2[b]!.compareTo(cc2[a]!);
            return d != 0 ? d : mv2[a]!.compareTo(mv2[b]!);
          });
          bool imp2 = false;
          for (final i in cf) { if (trySingleMoveFull(i)) imp2 = true; }
          if (!imp2) break;
        }
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 3 — Targeted Iterated Perturbation (80 rounds)
    //
    // Instead of perturbing ALL clashing genes randomly, score each gene by the
    // number of conflicts it causes and perturb the WORST OFFENDERS first
    // (plus a random subset of clash-free genes to shake up blocked neighbours).
    // This focuses disruption where it can do the most good.
    // ─────────────────────────────────────────────────────────────────────────
    {
      final rng3 = Random();

      int countHardClashes() {
        int c = 0;
        for (int i = 0; i < n; i++) {
          if (placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i])) c++;
        }
        return c;
      }

      _Chrom snapshotChrom(_Chrom src) {
        final s = _Chrom(n);
        for (int i = 0; i < n; i++) {
          s.startDays[i] = src.startDays[i];
          s.timeSlots[i] = src.timeSlots[i];
          s.rooms[i]     = src.rooms[i];
        }
        return s;
      }

      void restoreChrom(_Chrom dst, _Chrom src) {
        for (int i = 0; i < n; i++) {
          dst.startDays[i] = src.startDays[i];
          dst.timeSlots[i] = src.timeSlots[i];
          dst.rooms[i]     = src.rooms[i];
        }
      }

      void runSweepsAndSwaps() {
        // Mini-version of stages 1+2 used inside each perturbation round
        for (int sweep = 0; sweep < 30; sweep++) {
          final cf = collectClashingFree();
          if (cf.isEmpty) break;
          final cc = <int, int>{for (final i in cf) i: clashCountFor(i)};
          final mv = <int, int>{for (final i in cf) i: candidateCount(i)};
          cf.sort((a, b) {
            final d = cc[b]!.compareTo(cc[a]!);
            return d != 0 ? d : mv[a]!.compareTo(mv[b]!);
          });
          bool imp = false;
          for (final i in cf) { if (trySingleMoveFull(i)) imp = true; }
          if (!imp) break;
        }
        // Swap pass
        for (int sp = 0; sp < 10; sp++) {
          final cf = collectClashingFree();
          if (cf.isEmpty) break;
          bool imp = false;
          for (final i in cf) {
            if (!placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i])) continue;
            if (customDays[i].isNotEmpty) continue;
            final slotLockedI = lockedSlotIdx[i] >= 0;
            final dayLockedI  = lockedStartDay[i] >= 1;
            final tsI = bestChrom.timeSlots[i], sdI = bestChrom.startDays[i];
            for (int j = 0; j < n; j++) {
              if (j == i || genesConflict(i, j) || customDays[j].isNotEmpty) continue;
              final slotLockedJ = lockedSlotIdx[j] >= 0;
              final dayLockedJ  = lockedStartDay[j] >= 1;
              final tsJ = bestChrom.timeSlots[j], sdJ = bestChrom.startDays[j];
              if (slotLockedI  && tsI != tsJ) continue;
              if (slotLockedJ  && tsJ != tsI) continue;
              if (!slotLockedI && !validSlotIdxs[i].contains(tsJ)) continue;
              if (!slotLockedJ && !validSlotIdxs[j].contains(tsI)) continue;
              bestChrom.timeSlots[i] = tsJ; if (!dayLockedI) bestChrom.startDays[i] = sdJ.clamp(1, maxStarts[i]).toInt();
              bestChrom.timeSlots[j] = tsI; if (!dayLockedJ) bestChrom.startDays[j] = sdI.clamp(1, maxStarts[j]).toInt();
              final iOk = !placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i]);
              final jOk = !placementClashes(j, bestChrom.startDays[j], bestChrom.timeSlots[j]);
              if (iOk && jOk) { imp = true; break; }
              bestChrom.timeSlots[i] = tsI; if (!dayLockedI) bestChrom.startDays[i] = sdI;
              bestChrom.timeSlots[j] = tsJ; if (!dayLockedJ) bestChrom.startDays[j] = sdJ;
            }
          }
          if (!imp) break;
          final cf2 = collectClashingFree();
          final cc2 = <int, int>{for (final i in cf2) i: clashCountFor(i)};
          final mv2 = <int, int>{for (final i in cf2) i: candidateCount(i)};
          cf2.sort((a, b) {
            final d = cc2[b]!.compareTo(cc2[a]!);
            return d != 0 ? d : mv2[a]!.compareTo(mv2[b]!);
          });
          for (final i in cf2) { trySingleMoveFull(i); }
        }
      }

      int bestClashes = countHardClashes();
      if (bestClashes > 0) {
        final bestSaved = snapshotChrom(bestChrom);
        const maxPerturbRounds = 80;

        for (int round = 0; round < maxPerturbRounds && bestClashes > 0; round++) {
          final toPerturb = collectClashingFree();
          if (toPerturb.isEmpty) break;
          final saved = snapshotChrom(bestChrom);

          // Score each clashing gene by how many conflicts IT causes
          final conflictScore = <int, int>{
            for (final i in toPerturb) i: clashCountFor(i),
          };
          // Sort: most-conflicting genes get perturbed first
          toPerturb.sort((a, b) => conflictScore[b]!.compareTo(conflictScore[a]!));

          // Perturb worst offenders
          for (final i in toPerturb) {
            final slotLockedI = lockedSlotIdx[i] >= 0;
            final dayLockedI  = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
            if (slotLockedI && dayLockedI) continue;
            if (!slotLockedI && validSlotIdxs[i].isNotEmpty) {
              final opts = validSlotIdxs[i];
              // Try a slot DIFFERENT from current to ensure real movement
              if (opts.length > 1) {
                int newTs;
                do { newTs = opts[rng3.nextInt(opts.length)]; }
                while (newTs == bestChrom.timeSlots[i] && opts.length > 1);
                bestChrom.timeSlots[i] = newTs;
              } else {
                bestChrom.timeSlots[i] = opts[0];
              }
            }
            if (!dayLockedI && customDays[i].isEmpty) {
              final maxSd = maxStarts[i];
              if (maxSd > 0) bestChrom.startDays[i] = rng3.nextInt(maxSd) + 1;
            }
          }

          // Also shake a random sample of clash-free free genes (neighbourhood
          // perturbation — helps unlock genes blocked by their neighbours)
          final shakeCount = (n * 0.08).round().clamp(1, 12);
          for (int s = 0; s < shakeCount; s++) {
            final i = rng3.nextInt(n);
            if (lockedSlotIdx[i] >= 0 && (lockedStartDay[i] >= 1 || customDays[i].isNotEmpty)) continue;
            if (customDays[i].isNotEmpty) continue;
            if (!placementClashes(i, bestChrom.startDays[i], bestChrom.timeSlots[i])) {
              // Only shake clash-free genes occasionally
              if (lockedSlotIdx[i] < 0 && validSlotIdxs[i].length > 1) {
                bestChrom.timeSlots[i] = validSlotIdxs[i][rng3.nextInt(validSlotIdxs[i].length)];
              }
              if (lockedStartDay[i] < 1) {
                final ms = maxStarts[i];
                if (ms > 1) bestChrom.startDays[i] = rng3.nextInt(ms) + 1;
              }
            }
          }

          runSweepsAndSwaps();

          final newClashes = countHardClashes();
          if (newClashes < bestClashes) {
            bestClashes = newClashes;
            restoreChrom(bestSaved, bestChrom);
          } else {
            restoreChrom(bestChrom, saved);
          }
        }
        restoreChrom(bestChrom, bestSaved);
      }

      // ─────────────────────────────────────────────────────────────────────
      // STAGE 4 — Global greedy restart (up to 5 attempts)
      // If clashes remain, rebuild ALL free genes from scratch using greedy
      // placement (same logic as the population seeder), then re-run stages
      // 1-3 on the result. This completely escapes the local optimum the GA
      // settled on. Accept if better than the best found so far.
      // ─────────────────────────────────────────────────────────────────────
      bestClashes = countHardClashes();
      if (bestClashes > 0) {
        final bestSaved4 = snapshotChrom(bestChrom);

        for (int attempt = 0; attempt < 5 && bestClashes > 0; attempt++) {
          // Rebuild free genes using a greedy clash-aware pass
          // Locked genes stay in place; free genes are re-placed in conflict order.
          final saved4 = snapshotChrom(bestChrom);

          // Collect free genes and sort by number of constraints (most constrained first)
          final freeGenes = <int>[];
          for (int i = 0; i < n; i++) {
            final sl = lockedSlotIdx[i] >= 0;
            final dl = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
            if (!sl || !dl) freeGenes.add(i);
          }
          freeGenes.shuffle(rng3);

          // Reset all free genes to random positions first
          for (final i in freeGenes) {
            final slotLocked = lockedSlotIdx[i] >= 0;
            final dayLocked  = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
            if (!slotLocked && validSlotIdxs[i].isNotEmpty) {
              bestChrom.timeSlots[i] = validSlotIdxs[i][rng3.nextInt(validSlotIdxs[i].length)];
            }
            if (!dayLocked && customDays[i].isEmpty) {
              final ms = maxStarts[i];
              if (ms > 0) bestChrom.startDays[i] = rng3.nextInt(ms) + 1;
            }
          }

          // Greedy pass: for each free gene in conflict order, find best position
          for (final i in freeGenes) {
            final slotLocked = lockedSlotIdx[i] >= 0;
            final dayLocked  = lockedStartDay[i] >= 1 || customDays[i].isNotEmpty;
            final slotOpts   = slotLocked ? [bestChrom.timeSlots[i]] : validSlotIdxs[i];
            final maxSd      = maxStarts[i];
            final dayOpts    = dayLocked
                ? [bestChrom.startDays[i]]
                : List<int>.generate(maxSd, (k) => k + 1);

            int bestTs = bestChrom.timeSlots[i];
            int bestSd = bestChrom.startDays[i];
            int bestC  = clashCountIfAt(i, bestSd, bestTs);
            if (bestC == 0) continue; // already clash-free

            for (final ts in slotOpts) {
              for (final sd in dayOpts) {
                final c = clashCountIfAt(i, sd, ts);
                if (c == 0) { bestTs = ts; bestSd = sd; bestC = 0; break; }
                if (c < bestC) { bestC = c; bestTs = ts; bestSd = sd; }
              }
              if (bestC == 0) break;
            }
            bestChrom.timeSlots[i] = bestTs;
            if (!dayLocked) bestChrom.startDays[i] = bestSd;
          }

          // Re-run full stages 1-3 on the rebuilt chromosome
          for (int sweep = 0; sweep < 40; sweep++) {
            final cf = collectClashingFree();
            if (cf.isEmpty) break;
            final cc = <int, int>{for (final i in cf) i: clashCountFor(i)};
            final mv = <int, int>{for (final i in cf) i: candidateCount(i)};
            cf.sort((a, b) {
              final d = cc[b]!.compareTo(cc[a]!);
              return d != 0 ? d : mv[a]!.compareTo(mv[b]!);
            });
            bool imp = false;
            for (final i in cf) { if (trySingleMoveFull(i)) imp = true; }
            if (!imp) break;
          }
          runSweepsAndSwaps();

          final newClashes = countHardClashes();
          if (newClashes < bestClashes) {
            bestClashes = newClashes;
            restoreChrom(bestSaved4, bestChrom);
          } else {
            restoreChrom(bestChrom, saved4);
          }
        }
        restoreChrom(bestChrom, bestSaved4);
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 5 — Smart Day Spread (same-slot teacher clash redistribution)
    //
    // For each teacher who has multiple assignments in the SAME time slot but
    // on the SAME days (creating a teacher clash), redistribute the start days
    // so the assignments get non-overlapping day windows.
    // Example: 3 sections of Pak Studies (2cr each) all pinned to slot P1 on
    // Mon–Tue → moved to Mon–Tue / Wed–Thu / Fri–Sat in the same slot.
    // This works even for fully-locked genes because the slot doesn't change.
    // The day redistribution respects per-class clashes and Friday rules.
    // ─────────────────────────────────────────────────────────────────────────
    {
      // Build (teacher, slotIdx) → list of gene indices
      final Map<String, List<int>> teacherSlotBuckets = {};
      for (int i = 0; i < n; i++) {
        if (teacherIds[i].isEmpty) continue;
        final key = '${teacherIds[i]}|||${bestChrom.timeSlots[i]}';
        teacherSlotBuckets.putIfAbsent(key, () => []).add(i);
      }

      for (final bucket in teacherSlotBuckets.values) {
        if (bucket.length < 2) continue;

        // Check that at least one pair in this bucket is clashing on overlapping days
        bool hasOverlap = false;
        for (int x = 0; x < bucket.length && !hasOverlap; x++) {
          final i = bucket[x];
          final iDays = geneDays(i, bestChrom.startDays[i]);
          for (int y = x + 1; y < bucket.length; y++) {
            final j = bucket[y];
            if (!genesConflict(i, j)) continue; // different teacher somehow? skip
            final jDays = geneDays(j, bestChrom.startDays[j]);
            bool dayOv = false;
            for (final d in iDays) { if (jDays.contains(d)) { dayOv = true; break; } }
            if (dayOv) { hasOverlap = true; break; }
          }
        }
        if (!hasOverlap) continue;

        // Skip ONLY buckets with truly non-consecutive customDays (e.g. [1,3,5]).
        // Consecutive customDays like [1,2] or [3,4] are handled as startDay+duration.
        bool hasNonConsecutive = false;
        for (final i in bucket) {
          final cd = customDays[i];
          if (cd.length > 1) {
            final sorted = [...cd]..sort();
            for (int k = 0; k < sorted.length - 1; k++) {
              if (sorted[k + 1] != sorted[k] + 1) { hasNonConsecutive = true; break; }
            }
          }
          if (hasNonConsecutive) break;
        }
        if (hasNonConsecutive) continue;

        // Total credit hours needed must fit in the working week
        final totalDays = bucket.fold<int>(0, (s, i) => creditHours[i] + s);
        if (totalDays > wDays) continue;

        // Sort by existing startDay so earlier assignments keep their position
        final sorted = [...bucket]
          ..sort((i, j) => bestChrom.startDays[i].compareTo(bestChrom.startDays[j]));

        // Greedy assignment of non-overlapping day windows
        int nextDay = 1;
        bool feasible = true;
        final proposals = <int, int>{}; // gene idx → new startDay

        for (final i in sorted) {
          final dur = creditHours[i];
          bool placed = false;
          final tsI = bestChrom.timeSlots[i];
          final sI = slotStart[tsI], eI = slotEnd[tsI];

          for (int sd = nextDay; sd + dur - 1 <= wDays; sd++) {
            // Check class-level conflicts at the proposed new days
            final newDays = List.generate(dur, (k) => sd + k);
            bool classConflict = false;
            for (int j = 0; j < n; j++) {
              if (j == i) continue;
              // Must share a class conflict (same section/discipline, different course)
              if (!(disciplineIds[i] == disciplineIds[j] &&
                    sectionIds[i]    == sectionIds[j]   &&
                    courseIds[i]     != courseIds[j])) { continue; }
              if (isElective[i] && isElective[j] &&
                  electiveGroupIds[i] == electiveGroupIds[j]) { continue; }
              // Clock overlap?
              final tsJ = bestChrom.timeSlots[j];
              final sJ = slotStart[tsJ], eJ = slotEnd[tsJ];
              bool clockOv;
              if (eI > 0 && eJ > 0) {
                clockOv = (sI < eJ) && (sJ < eI);
              } else {
                clockOv = tsI == tsJ;
              }
              if (!clockOv) continue;
              // Day overlap with proposed window?
              final jSd = proposals.containsKey(j) ? proposals[j]! : bestChrom.startDays[j];
              final jDays = List.generate(creditHours[j], (k) => (jSd + k).clamp(1, wDays));
              bool dayOv = false;
              for (final d in newDays) { if (jDays.contains(d)) { dayOv = true; break; } }
              if (dayOv) { classConflict = true; break; }
            }
            if (classConflict) continue;

            proposals[i] = sd;
            nextDay = sd + dur;
            placed = true;
            break;
          }
          if (!placed) { feasible = false; break; }
        }

        if (!feasible) continue;

        // Apply proposals — only change genes whose start day actually moves
        for (final e in proposals.entries) {
          final i = e.key;
          final newSd = e.value;
          if (bestChrom.startDays[i] == newSd) continue;
          bestChrom.startDays[i] = newSd;
          // Note: we deliberately allow changing locked start days here because
          // the slot is unchanged — this is a day-shift within the same period,
          // which is the minimum change needed to resolve the teacher clash.
        }
      }
    }
  } // end outer sweep block



  // ── Convert back to Map format expected by the rest of the app ─────────────
  final chromosome = List<Map<String, dynamic>>.generate(n, (i) {
    final sd  = bestChrom.startDays[i];
    final cr  = creditHours[i];
    final ts  = bestChrom.timeSlots[i];
    final rm  = roomList[bestChrom.rooms[i]];
    final cDays = customDays[i];
    final block = cDays.isNotEmpty ? cDays : List<int>.generate(cr, (k) => (sd + k).clamp(1, wDays));
    return {
      'assignment_idx': i,
      'start_day':      sd,
      'day_block':      block,
      'time_slot_id':   allSlotIds[ts],
      'room_id':        rm,
    };
  });

  final bd    = countClashesMap(chromosome, input.assignments,
      input.timeSlotIntervals, wDays);
  final total = bd['total_hard']!;
  final msg   = total == 0
      ? 'Clash-free schedule found in $gensRun generation(s) ✓'
      : 'Best schedule: $total clash(es) remain after $gensRun generation(s)';

  return GaOutput(
    chromosome:     chromosome,
    score:          bestScore,
    hardClashes:    total,
    generationsRun: gensRun,
    message:        msg,
    breakdown:      bd,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Fast fitness — works directly on _Chrom (no Map lookups in hot path)
// ─────────────────────────────────────────────────────────────────────────────

int _fitnessC(
    _Chrom c, int n, int wDays,
    List<int> lockedStartDay,
    List<int> lockedSlotIdx,
    List<int> lockedRoomIdx,
    List<String> disciplineIds,
    List<String> sectionIds,
    List<String> courseIds,
    List<int> maxStarts,
    List<int> slotStart,
    List<int> slotEnd,
    List<int> creditHours,
    List<String> teacherIds,
    List<bool> isElective,
    List<String> electiveGroupIds,
    List<List<int>> dtGrid,
    int numSlots,
    Map<int, List<Set<String>>> phantomClassSets,
    Map<int, List<Set<String>>> phantomTeacherSets,
    List<List<int>> customDays,
    Uint8List touchedFlag,
    List<int> touchedKeys,
    List<List<int>> overlapAdj,
    List<int> earliestAllowedStart,
    ) {
  int h1 = 0, h2 = 0, h3 = 0, s1 = 0;

  // Build day+slot → list of assignment indices
  // Key = day * numSlots + slotIdx (avoids map allocation completely).
  // Only cells actually written this call are tracked in touchedKeys, so the
  // clear/scan below cost O(cells occupied) instead of O(full grid size).

  for (int i = 0; i < n; i++) {
    final sd = c.startDays[i];
    final ts = c.timeSlots[i];
    final cr = creditHours[i];
    final cDays = customDays[i];
    if (cDays.isNotEmpty) {
      for (final day in cDays) {
        final key = day * numSlots + ts;
        if (touchedFlag[key] == 0) {
          touchedFlag[key] = 1;
          touchedKeys.add(key);
        }
        dtGrid[key].add(i);
      }
    } else {
      for (int d = 0; d < cr; d++) {
        final day = (sd + d).clamp(1, wDays);
        final key = day * numSlots + ts;
        if (touchedFlag[key] == 0) {
          touchedFlag[key] = 1;
          touchedKeys.add(key);
        }
        dtGrid[key].add(i);
      }
    }
    // S1 soft: prefer early periods, relative to the earliest slot THIS
    // assignment could actually use (its level/shift's real start), not a
    // hardcoded clock time — a later-starting shift must not be scored as
    // if it were running late.
    final startMin = slotStart[ts];
    final penalty  = (startMin - earliestAllowedStart[i]) ~/ 30;
    if (penalty > 0) s1 += penalty;

    // S2 soft: college PDF pattern — a course's day block anchors to a week
    // edge (starts Mon or ends on the last working day) so two courses tile a
    // period as (1-k)+(k+1-wDays). Weight MUST stay below one S1 period step
    // (2 per hour): earliness dominates, anchoring only breaks ties within a
    // period — otherwise courses drift to later periods just to anchor,
    // leaving the first period empty.
    int dFirst, dLast;
    if (cDays.isNotEmpty) {
      dFirst = cDays.reduce((a, b) => a < b ? a : b);
      dLast  = cDays.reduce((a, b) => a > b ? a : b);
    } else {
      dFirst = sd.clamp(1, wDays);
      dLast  = (sd + cr - 1).clamp(1, wDays);
    }
    if (dFirst != 1 && dLast != wDays) s1 += 1;

    // HARD: elective phantom clash
    if (phantomClassSets.isNotEmpty || phantomTeacherSets.isNotEmpty) {
      final cDays = customDays[i];
      if (cDays.isNotEmpty) {
        for (final day in cDays) {
          final key = day * numSlots + ts;
          final pCls = phantomClassSets[key];
          if (pCls != null) {
            for (final s in pCls) {
              if (s.contains(disciplineIds[i])) { h3++; break; }
            }
          }
          final pTch = phantomTeacherSets[key];
          if (pTch != null && teacherIds[i].isNotEmpty) {
            for (final s in pTch) {
              if (s.contains(teacherIds[i])) { h1++; break; }
            }
          }
        }
      } else {
        for (int d = 0; d < cr; d++) {
          final day = (sd + d).clamp(1, wDays);
          final key = day * numSlots + ts;
          final pCls = phantomClassSets[key];
          if (pCls != null) {
            for (final s in pCls) {
              if (s.contains(disciplineIds[i])) { h3++; break; }
            }
          }
          final pTch = phantomTeacherSets[key];
          if (pTch != null && teacherIds[i].isNotEmpty) {
            for (final s in pTch) {
              if (s.contains(teacherIds[i])) { h1++; break; }
            }
          }
        }
      }
    }
  }

  // Check clashes across every clock-overlapping (day, slot) bucket pair.
  // CROSS-LEVEL FIX: a teacher in Bachelor P1 (08:00-09:00) also collides
  // with Intermediate P1 (08:00-08:40) and P2 (08:40-09:20) — different slot
  // indices, same real time. overlapAdj[ts] lists every slot index >= ts that
  // clock-overlaps ts (self included), so scanning bucket(day,ts) against
  // bucket(day,ts2) for ts2 in overlapAdj[ts] covers ALL real-time collisions
  // on that day exactly once.
  void compareGenes(int gi, int gj) {
    if (teacherIds[gi] == teacherIds[gj] && teacherIds[gi].isNotEmpty) h1++;

    final ri = c.rooms[gi];
    final rj = c.rooms[gj];
    // Index 0 is the "no room needed" sentinel (roomList[0] == null) —
    // many classes can simultaneously need no room, so that's not a clash.
    if (ri == rj && ri != 0) h2++;

    if (disciplineIds[gi] == disciplineIds[gj] &&
        sectionIds[gi]    == sectionIds[gj]    &&
        courseIds[gi]     != courseIds[gj]) {
          if (!(isElective[gi] && isElective[gj] && electiveGroupIds[gi] == electiveGroupIds[gj])) {
              h3++;
          }
    }
  }

  for (final key in touchedKeys) {
    final bucket = dtGrid[key];
    if (bucket.isEmpty) continue;
    final day = key ~/ numSlots;
    final ts  = key %  numSlots;

    // 1) Same-bucket pairs (same day, same slot — always same clock time)
    final bLen = bucket.length;
    for (int i = 0; i < bLen; i++) {
      for (int j = i + 1; j < bLen; j++) {
        compareGenes(bucket[i], bucket[j]);
      }
    }

    // 2) Cross-bucket pairs: same day, DIFFERENT slot index, real clock overlap.
    //    overlapAdj[ts] only lists ts2 > ts (plus ts itself, skipped here), so
    //    each (bucketA, bucketB) pair is visited exactly once per day.
    final adj = overlapAdj[ts];
    for (final ts2 in adj) {
      if (ts2 == ts) continue;
      final key2 = day * numSlots + ts2;
      final bucket2 = dtGrid[key2];
      if (bucket2.isEmpty) continue;
      for (final gi in bucket) {
        for (final gj in bucket2) {
          compareGenes(gi, gj);
        }
      }
    }
  }

  // Reset buckets after ALL scanning (must not clear inside the scan loop —
  // cross-bucket pairs need every bucket intact until the end).
  for (final key in touchedKeys) {
    dtGrid[key].clear();
    touchedFlag[key] = 0;
  }
  touchedKeys.clear();

  return (h1 + h2 + h3) * 10000 + s1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Chromosome initialisation
// ─────────────────────────────────────────────────────────────────────────────

_Chrom _randomChrom(
    int n, int wDays,
    List<int> maxStarts,
    List<List<int>> validSlotIdxs,
    int roomCount,
    List<int> lockedSlotIdx,
    List<int> lockedStartDay,
    List<int> lockedRoomIdx,
    Random rng) {
  final c = _Chrom(n);
  for (int i = 0; i < n; i++) {
    // Respect manually locked start day
    final lDay = lockedStartDay[i];
    c.startDays[i] = lDay >= 1 ? lDay : (rng.nextInt(maxStarts[i]) + 1);
    // Respect locked time slot
    final locked   = lockedSlotIdx[i];
    c.timeSlots[i] = locked >= 0 ? locked : validSlotIdxs[i][rng.nextInt(validSlotIdxs[i].length)];
    final lockedRoom = lockedRoomIdx[i];
    // Rooms are manual-only (assigned via the separate Room Allocation UI) —
    // the GA never invents one; an unlocked gene starts at the "no room"
    // sentinel (index 0) instead of a random real room.
    c.rooms[i]     = (lockedRoom >= 0 && lockedRoom < roomCount) ? lockedRoom : 0;
  }
  return c;
}

// ─────────────────────────────────────────────────────────────────────────────
// Crossover — single-point, creates a new _Chrom in-place (no Map copies)
// ─────────────────────────────────────────────────────────────────────────────

_Chrom _crossoverC(_Chrom p1, _Chrom p2, Random rng, int n) {
  final child = _Chrom(n);
  final pt    = n <= 1 ? 0 : rng.nextInt(n);
  for (int i = 0; i < n; i++) {
    final src = i < pt ? p1 : p2;
    child.startDays[i] = src.startDays[i];
    child.timeSlots[i] = src.timeSlots[i];
    child.rooms[i]     = src.rooms[i];
  }
  return child;
}

// ─────────────────────────────────────────────────────────────────────────────
// Mutation — mutates in-place (no copy)
// ─────────────────────────────────────────────────────────────────────────────

void _mutateC(
    _Chrom c, int n, int wDays,
    List<int> maxStarts,
    List<List<int>> validSlotIdxs,
    int roomCount,
    List<int> lockedSlotIdx,
    List<int> lockedStartDay,
    List<int> lockedRoomIdx,
    double rate,
    Random rng) {
  for (int i = 0; i < n; i++) {
    if (rng.nextDouble() >= rate) continue;
    // Never mutate a manually-locked start day
    final lDay = lockedStartDay[i];
    if (lDay < 1) {
      c.startDays[i] = rng.nextInt(maxStarts[i]) + 1;
    }
    // Never mutate a locked time slot
    final locked = lockedSlotIdx[i];
    if (locked < 0) {
      c.timeSlots[i] = validSlotIdxs[i][rng.nextInt(validSlotIdxs[i].length)];
    }
    // Rooms are manual-only — the GA never mutates a room gene, locked or not.
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Clash repair — greedy local nudge applied to freshly-bred children.
// Blind random mutation can take many generations to stumble onto a
// non-clashing slot combination when several full-week (creditHours==wDays)
// courses compete for the same narrow pool of legal slots for the same
// teacher/class. This walks the genes that are *currently* clashing (H1
// teacher / H2 room / H3 section, mirroring the predicates in _fitnessC) and
// tries known-legal alternative slots (and, for room clashes, alternative
// rooms) for just those genes, checking only the cells they'd move into
// against the pre-repair snapshot (not the whole chromosome) — cost is
// proportional to how many genes are clashing, not n.
// ─────────────────────────────────────────────────────────────────────────────

void _repairClashes(
    _Chrom c, int n, int wDays,
    List<int> creditHours,
    List<List<int>> customDays,
    List<List<int>> validSlotIdxs,
    List<int> lockedSlotIdx,
    List<String> teacherIds,
    List<String> disciplineIds,
    List<String> sectionIds,
    List<String> courseIds,
    List<bool> isElective,
    List<String> electiveGroupIds,
    int numSlots,
    Random rng,
    // Shared sparse-grid buffers reused from the outer fitness evaluation —
    // idle during breeding (this generation's evaluation already finished),
    // so reusing them here avoids allocating a fresh map per child/gen.
    List<List<int>> dtGrid,
    Uint8List touchedFlag,
    List<int> touchedKeys,
    int roomCount,
    List<int> lockedRoomIdx,
    List<List<int>> overlapAdj,
    ) {
  // Snapshot occupancy of the chromosome as it stands before repair.
  for (int i = 0; i < n; i++) {
    final sd = c.startDays[i];
    final ts = c.timeSlots[i];
    final cr = creditHours[i];
    final cDays = customDays[i];
    if (cDays.isNotEmpty) {
      for (final day in cDays) {
        final key = day * numSlots + ts;
        if (touchedFlag[key] == 0) {
          touchedFlag[key] = 1;
          touchedKeys.add(key);
        }
        dtGrid[key].add(i);
      }
    } else {
      for (int d = 0; d < cr; d++) {
        final day = (sd + d).clamp(1, wDays);
        final key = day * numSlots + ts;
        if (touchedFlag[key] == 0) {
          touchedFlag[key] = 1;
          touchedKeys.add(key);
        }
        dtGrid[key].add(i);
      }
    }
  }

  bool clashesWith(int gi, int gj) {
    if (teacherIds[gi] == teacherIds[gj] && teacherIds[gi].isNotEmpty) return true;
    if (disciplineIds[gi] == disciplineIds[gj] &&
        sectionIds[gi]    == sectionIds[gj]    &&
        courseIds[gi]     != courseIds[gj]) {
      if (!(isElective[gi] && isElective[gj] && electiveGroupIds[gi] == electiveGroupIds[gj])) {
        return true;
      }
    }
    return false;
  }

  // Room index 0 is the "no room needed" sentinel — only a shared nonzero
  // room index is a real clash (mirrors the H2 check in _fitnessC).
  bool roomClashesWith(int gi, int gj) =>
      c.rooms[gi] == c.rooms[gj] && c.rooms[gi] != 0;

  // Find genes involved in at least one real clash, split by repair
  // strategy: teacher/section clashes need a time-slot move; room clashes
  // need a room swap instead (moving time wouldn't fix — or would even
  // needlessly disturb — a gene that only clashes on room). A gene can need
  // both if it has more than one clash type.
  final timeClashGenes = <int>{};
  final roomClashGenes = <int>{};
  void markPair(int gi, int gj) {
    if (clashesWith(gi, gj)) {
      timeClashGenes.add(gi);
      timeClashGenes.add(gj);
    }
    if (roomClashesWith(gi, gj)) {
      roomClashGenes.add(gi);
      roomClashGenes.add(gj);
    }
  }
  for (final key in touchedKeys) {
    final bucket = dtGrid[key];
    if (bucket.isEmpty) continue;
    final day = key ~/ numSlots;
    final ts  = key %  numSlots;
    final bLen = bucket.length;
    // Same-bucket pairs
    for (int a = 0; a < bLen; a++) {
      for (int b = a + 1; b < bLen; b++) {
        markPair(bucket[a], bucket[b]);
      }
    }
    // Cross-bucket pairs — clock-overlapping slots on the same day
    // (Bach 08:00-09:00 vs Inter 08:00-08:40 / 08:40-09:20 etc.)
    for (final ts2 in overlapAdj[ts]) {
      if (ts2 == ts) continue;
      final bucket2 = dtGrid[day * numSlots + ts2];
      if (bucket2.isEmpty) continue;
      for (final gi in bucket) {
        for (final gj in bucket2) {
          markPair(gi, gj);
        }
      }
    }
  }
  final clashingGenes = <int>{...timeClashGenes, ...roomClashGenes};

  // Safety valve: when assignments vastly outnumber available (day, slot)
  // cells, nearly every gene can end up "clashing" with huge buckets — the
  // per-candidate scan cost (bounded by bucket size) stops being small and
  // repairing ALL of them stops being worth its cost. In that regime, cap
  // the repair pass at a fixed budget of genes (same bound as before) instead
  // of skipping repair entirely — partial repair still helps convergence,
  // and the worst-case cost per call stays identical to the old behavior.
  final repairBudget = n < 200 ? n : 200;
  if (clashingGenes.isNotEmpty) {
    final toRepair = clashingGenes.length <= repairBudget
        ? clashingGenes
        : (clashingGenes.toList()..shuffle(rng)).take(repairBudget);
    for (final i in toRepair) {
      final sd = c.startDays[i];
      final cr = creditHours[i];
      final cDays = customDays[i];
      final days = cDays.isNotEmpty
          ? cDays
          : List<int>.generate(cr, (k) => (sd + k).clamp(1, wDays));

      // ── Time-slot repair (teacher/section clashes) ──────────────────────
      if (timeClashGenes.contains(i) && lockedSlotIdx[i] < 0) {
        final options = validSlotIdxs[i];
        if (options.length > 1) {
          final originalSlot = c.timeSlots[i];
          // Try each candidate slot (shuffled) once; accept the first that
          // clears this gene's own cells against the pre-repair occupants
          // (cheap check, proportional to creditHours x small bucket size,
          // not n). Also reject a candidate that would trade the teacher/
          // section clash for a fresh room clash at the new cells.
          final shuffled = List<int>.of(options)..shuffle(rng);
          for (final candidate in shuffled) {
            if (candidate == originalSlot) continue;
            bool clashFree = true;
            for (final day in days) {
              // Check the candidate's own bucket AND every clock-overlapping
              // bucket on the same day (cross-level: Bach vs Inter slots).
              // overlapAdj lists indices >= candidate; lower indices that
              // overlap the candidate list IT in their rows instead, so scan
              // both directions via a linear pass over the candidate's row
              // plus rows whose adjacency contains the candidate.
              bool cellClashes(int slotIdx) {
                for (final gj in dtGrid[day * numSlots + slotIdx]) {
                  if (gj == i) continue;
                  if (clashesWith(i, gj)) return true;
                  if (slotIdx == candidate &&
                      c.rooms[i] != 0 && c.rooms[gj] == c.rooms[i]) {
                    return true;
                  }
                }
                return false;
              }
              // candidate's row covers candidate + all higher overlapping idxs
              for (final ts2 in overlapAdj[candidate]) {
                if (cellClashes(ts2)) { clashFree = false; break; }
              }
              // lower indices whose row contains candidate
              if (clashFree) {
                for (int lower = 0; lower < candidate; lower++) {
                  if (overlapAdj[lower].contains(candidate) && cellClashes(lower)) {
                    clashFree = false; break;
                  }
                }
              }
              if (!clashFree) break;
            }
            if (clashFree) {
              c.timeSlots[i] = candidate;
              break;
            }
          }
        }
      }

      // ── Room repair (room clashes) ───────────────────────────────────────
      if (roomClashGenes.contains(i) && c.rooms[i] != 0 &&
          lockedRoomIdx[i] < 0 && roomCount > 1) {
        final curSlot = c.timeSlots[i];
        // Re-check against the pre-repair snapshot at this gene's (possibly
        // just-moved) slot — cheap since it's bounded by that cell's bucket.
        bool stillClashing = false;
        for (final day in days) {
          for (final gj in dtGrid[day * numSlots + curSlot]) {
            if (gj == i) continue;
            if (c.rooms[gj] == c.rooms[i]) { stillClashing = true; break; }
          }
          if (stillClashing) break;
        }
        if (stillClashing) {
          final candidateRooms = List<int>.generate(roomCount - 1, (k) => k + 1)..shuffle(rng);
          for (final room in candidateRooms) {
            if (room == c.rooms[i]) continue;
            bool free = true;
            for (final day in days) {
              for (final gj in dtGrid[day * numSlots + curSlot]) {
                if (gj == i) continue;
                if (c.rooms[gj] == room) { free = false; break; }
              }
              if (!free) break;
            }
            if (free) {
              c.rooms[i] = room;
              break;
            }
          }
        }
      }
    }
  }

  // Reset the shared buffers for reuse (by the next child's repair pass,
  // and by next generation's fitness evaluation).
  for (final key in touchedKeys) {
    dtGrid[key].clear();
    touchedFlag[key] = 0;
  }
  touchedKeys.clear();
}

// ─────────────────────────────────────────────────────────────────────────────
// Tournament selection
// ─────────────────────────────────────────────────────────────────────────────

_Chrom _tournament(List<_Chrom> pop, List<int> scores, Random rng, int popSize, {int k = 4}) {
  int best = rng.nextInt(popSize);
  for (int t = 1; t < k; t++) {
    final c = rng.nextInt(popSize);
    if (scores[c] < scores[best]) best = c;
  }
  return pop[best];
}

// ─────────────────────────────────────────────────────────────────────────────
// Final clash count in original Map format (called once at end)
// ─────────────────────────────────────────────────────────────────────────────

Map<String, int> countClashesMap(
    List<Map<String, dynamic>> chromosome,
    List<Map<String, dynamic>> assignments,
    Map<String, Map<String, int>> intervals,
    int wDays,
    ) {
  int h1 = 0, h2 = 0, h3 = 0, s1 = 0;

  // ── Soft penalty (unchanged) ────────────────────────────────────────────────
  for (int i = 0; i < chromosome.length; i++) {
    final gene  = chromosome[i];
    final ts    = gene['time_slot_id'] as String;
    final startMin = intervals[ts]?['start'] ?? 0;
    final penalty  = (startMin - 480) ~/ 30;
    if (penalty > 0) s1 += penalty;
    final block = gene['day_block'] as List<int>;
    if (block.isNotEmpty) {
      final dFirst = block.reduce((a, b) => a < b ? a : b);
      final dLast  = block.reduce((a, b) => a > b ? a : b);
      if (dFirst != 1 && dLast != wDays) s1 += 1;
    }
  }

  bool slotsClockOverlap(String a, String b) {
    if (a == b) return true;
    final ia = intervals[a], ib = intervals[b];
    if (ia == null || ib == null) return false;
    return max(ia['start']!, ib['start']!) < min(ia['end']!, ib['end']!);
  }

  // ── Hard clash counting — ONE count per clashing PAIR (not per day) ─────────
  // Build (gene_index → set of days it occupies) for overlap detection.
  // Then compare every pair of genes that share at least one day in the same
  // clock-overlapping slot, counting each pair at most once per clash TYPE
  // (teacher / room / section). This matches the Matrix screen's algorithm
  // exactly so both screens always show the same number.

  // gene → day set
  final List<Set<int>> geneDaySet = List.generate(chromosome.length, (i) {
    final block = chromosome[i]['day_block'] as List<int>;
    return block.toSet();
  });

  // gene → slot id
  final List<String> geneTs = [
    for (final g in chromosome) g['time_slot_id'] as String
  ];

  // Bucket genes by slotId to limit pair comparisons
  final Map<String, List<int>> bySlot = {};
  for (int i = 0; i < chromosome.length; i++) {
    bySlot.putIfAbsent(geneTs[i], () => []).add(i);
  }
  final slotIds = bySlot.keys.toList();

  for (int si = 0; si < slotIds.length; si++) {
    for (int sj = si; sj < slotIds.length; sj++) {
      if (!slotsClockOverlap(slotIds[si], slotIds[sj])) continue;
      final listA = bySlot[slotIds[si]]!;
      final listB = si == sj ? listA : bySlot[slotIds[sj]]!;
      final startJ = si == sj ? 0 : 0;
      for (int ai = 0; ai < listA.length; ai++) {
        final idxI = listA[ai];
        final gi = chromosome[idxI];
        final ai2 = assignments[gi['assignment_idx'] as int];
        for (int bi = (si == sj ? ai + 1 : startJ); bi < listB.length; bi++) {
          final idxJ = listB[bi];
          if (idxI == idxJ) continue;
          final gj = chromosome[idxJ];
          final aj = assignments[gj['assignment_idx'] as int];

          // Day overlap check — must share at least one day
          bool dayOv = false;
          for (final d in geneDaySet[idxI]) {
            if (geneDaySet[idxJ].contains(d)) { dayOv = true; break; }
          }
          if (!dayOv) continue;

          // Teacher clash
          final tid = ai2['teacher_id'] as String?;
          if (tid != null && tid.isNotEmpty && tid == aj['teacher_id']) h1++;

          // Room clash
          final ri = gi['room_id'];
          final rj = gj['room_id'];
          if (ri != null && rj != null && ri == rj) h2++;

          // Section clash
          if (ai2['discipline_id'] == aj['discipline_id'] &&
              ai2['section']       == aj['section']       &&
              ai2['course_id']     != aj['course_id']) {
            final sameElectiveGroup = ai2['is_elective'] == true &&
                aj['is_elective'] == true &&
                ai2['elective_group_id'] != null &&
                ai2['elective_group_id'] == aj['elective_group_id'];
            if (!sameElectiveGroup) h3++;
          }
        }
      }
    }
  }

  return {
    'H1_teacher_clash': h1,
    'H2_room_clash':    h2,
    'H3_section_clash': h3,
    'S1_late_period':   s1,
    'S2_class_gap':     0,
    'total_hard':       h1 + h2 + h3,
    'total_soft':       s1,
  };
}

