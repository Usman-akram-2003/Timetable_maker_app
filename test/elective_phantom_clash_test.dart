import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/services/ga_engine.dart';

// Regression test for the bug found 2026-08-14: countClashesMap (the sole
// source of the final reported hardClashes for both CSP and GA) never
// checked electiveOccupancy, so a schedule that seated a regular course on
// top of a class's own elective session was reported as clash-free and
// written to the live timetable.
void main() {
  test('countClashesMap flags a gene seated on top of its class\'s elective slot', () {
    final chromosome = [
      {
        'assignment_idx': 0,
        'start_day': 1,
        'day_block': [1, 2],
        'time_slot_id': 'ts_int_6',
        'room_id': null,
      },
    ];
    final assignments = [
      {
        'teacher_id': 't_urdu',
        'course_id': 'c_urdu',
        'discipline_id': 'class_A',
        'section': 'A',
        'level': '0',
      },
    ];
    final intervals = {
      'ts_int_6': {'start': 705, 'end': 750},
    };
    final electiveOccupancy = [
      {
        'slot_id': 'ts_int_6',
        'class_ids': ['class_A'],
        'teacher_ids': ['t_islami'],
        'days': [1, 2],
      },
    ];

    final withoutElectives = countClashesMap(chromosome, assignments, intervals, 6);
    expect(withoutElectives['total_hard'], 0,
        reason: 'documents the old blind spot: no phantom data in, no clash out');

    final withElectives = countClashesMap(chromosome, assignments, intervals, 6,
        electiveOccupancy: electiveOccupancy);
    expect(withElectives['H3_section_clash'], 1);
    expect(withElectives['total_hard'], 1,
        reason: 'the class already has an elective in this slot/day — must count as a hard clash');
  });

  test('countClashesMap stays clash-free when the elective is on different days', () {
    final chromosome = [
      {
        'assignment_idx': 0,
        'start_day': 3,
        'day_block': [3, 4, 5, 6],
        'time_slot_id': 'ts_int_6',
        'room_id': null,
      },
    ];
    final assignments = [
      {
        'teacher_id': 't_urdu',
        'course_id': 'c_urdu',
        'discipline_id': 'class_A',
        'section': 'A',
        'level': '0',
      },
    ];
    final intervals = {
      'ts_int_6': {'start': 705, 'end': 750},
    };
    // Elective only occupies days 1-2 — the leftover days (3-6) are free.
    final electiveOccupancy = [
      {
        'slot_id': 'ts_int_6',
        'class_ids': ['class_A'],
        'teacher_ids': ['t_islami'],
        'days': [1, 2],
      },
    ];

    final result = countClashesMap(chromosome, assignments, intervals, 6,
        electiveOccupancy: electiveOccupancy);
    expect(result['total_hard'], 0);
  });
}
