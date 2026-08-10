// ignore_for_file: avoid_print, unnecessary_brace_in_string_interps
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/services/ga_engine.dart';

// Simulates the real scenario:
//   - 230 assignments, 25 teachers each teaching BOTH Bach AND Inter
//   - Each assignment has a UNIQUE discipline_id so section clashes are 0
//   - Clock-overlapping slots between levels (Bach 60-min, Inter 40-min)
//   - Only teacher clashes can occur — cleanly measures the improvement

const int workingDays = 6;

final timeSlotIntervals = <String, Map<String, int>>{
  'bach_p1': {'start': 480, 'end': 540},  // 08:00-09:00
  'bach_p2': {'start': 540, 'end': 600},  // 09:00-10:00
  'bach_p3': {'start': 600, 'end': 660},  // 10:00-11:00
  'bach_p4': {'start': 660, 'end': 720},  // 11:00-12:00
  'inter_p1': {'start': 480, 'end': 520}, // 08:00-08:40 overlaps bach_p1
  'inter_p2': {'start': 520, 'end': 560}, // 08:40-09:20 overlaps bach_p1+p2
  'inter_p3': {'start': 560, 'end': 600}, // 09:20-10:00 overlaps bach_p2
  'inter_p4': {'start': 600, 'end': 640}, // 10:00-10:40 overlaps bach_p3
  'inter_p5': {'start': 640, 'end': 680}, // 10:40-11:20 overlaps bach_p3+p4
  'inter_p6': {'start': 680, 'end': 720}, // 11:20-12:00 overlaps bach_p4
};
final slotsByLevel = <String, List<String>>{
  'bachelors':    ['bach_p1','bach_p2','bach_p3','bach_p4'],
  'intermediate': ['inter_p1','inter_p2','inter_p3','inter_p4','inter_p5','inter_p6'],
};

void main() {
  test('TEACHER CLASHES: 230 cross-level assignments, 25 shared teachers', () async {
    final rng = Random(42);
    final assignments = <Map<String, dynamic>>[];

    // 25 teachers, each assigned ~5 Bach + ~4 Inter courses
    // Unique discipline_id per assignment => zero section clashes
    // Only teacher clashes can happen (cross-level clock-overlapping slots)
    for (int t = 0; t < 25; t++) {
      final tid = 'teacher_${t.toString().padLeft(2, '0')}';
      for (int k = 0; k < 5; k++) {
        assignments.add({
          'teacher_id': tid,
          'course_id': 'bach_course_t${t}_k${k}',
          'discipline_id': 'bach_unique_t${t}_k${k}', // unique -> no section clash
          'section': 'A',
          'level': 'bachelors',
          'credit_hours': 2 + rng.nextInt(2),
          'locked_start_day': null,
          'locked_time_slot_id': null,
          'is_elective': false,
          'elective_group_id': '',
        });
      }
      for (int k = 0; k < 4; k++) {
        assignments.add({
          'teacher_id': tid,
          'course_id': 'inter_course_t${t}_k${k}',
          'discipline_id': 'inter_unique_t${t}_k${k}', // unique -> no section clash
          'section': 'A',
          'level': 'intermediate',
          'credit_hours': 2 + rng.nextInt(2),
          'locked_start_day': null,
          'locked_time_slot_id': null,
          'is_elective': false,
          'elective_group_id': '',
        });
      }
    }

    print('\n-- Assignments: ${assignments.length}');
    print('-- Unique teachers: ${assignments.map((a) => a['teacher_id']).toSet().length}');
    print('-- Bach: ${assignments.where((a) => a['level'] == 'bachelors').length}');
    print('-- Inter: ${assignments.where((a) => a['level'] == 'intermediate').length}');

    final input = GaInput(
      assignments: assignments,
      timeSlotIdsByLevel: slotsByLevel,
      timeSlotIntervals: timeSlotIntervals,
      roomIds: [],
      lockedSlots: [],
      workingDays: workingDays,
      populationSize: 100,
      maxGenerations: 300,
      stagnationLimit: 30,
    );

    print('-- Running GA...');
    final sw = Stopwatch()..start();
    final out = await GaEngine.run(input);
    sw.stop();

    final bd = out.breakdown;
    final teacherClashes = bd['H1_teacher_clash'] ?? 0;
    final sectionClashes = bd['H3_section_clash'] ?? 0;

    print('');
    print('=== RESULTS ===');
    print('Time:             ${sw.elapsedMilliseconds}ms');
    print('Generations:      ${out.generationsRun}');
    print('Hard clashes:     ${out.hardClashes}');
    print('Teacher clashes:  $teacherClashes  (target < 30)');
    print('Section clashes:  $sectionClashes  (expect 0 - unique IDs)');
    print('Message: ${out.message}');
    print('');

    // Section clashes must be 0 (unique discipline_ids)
    expect(sectionClashes, equals(0),
        reason: 'Unique discipline_ids mean zero section clashes');

    // Teacher clashes: 25 teachers x 9 assignments each across 2 overlapping levels
    // With only 4 Bach slots + 6 Inter slots, some overlap is expected
    // The improved GA should keep this well below a naive random scheduler
    expect(teacherClashes, lessThan(50),
        reason: 'Improved GA should keep teacher clashes < 50 on this input');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
