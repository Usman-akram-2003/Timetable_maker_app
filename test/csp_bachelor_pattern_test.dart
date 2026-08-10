import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/services/csp_scheduler.dart';
import 'package:timetable_maker_app/services/ga_engine.dart';

// One BS class, four courses totalling 12 credit-days over a 6-day week.
// The official college pattern (BS II/IV/VI timetable) tiles two courses
// per period with complementary anchored day blocks, filling early periods
// first: expected result is b1={1-4}+{5-6}, b2={1-3}+{4-6}, b3 untouched.
Map<String, dynamic> asn(String course, String teacher, int cr,
        {String cls = 'BS1'}) =>
    {
      'id': '$cls-$course',
      'course_id': course,
      'teacher_id': teacher,
      'discipline_id': cls,
      'section': 'A',
      'level': '1',
      'credit_hours': cr,
    };

void main() {
  test('bachelor allocations follow the college BS pattern', () async {
    final input = GaInput(
      assignments: [
        asn('C4', 't1', 4),
        asn('C2', 't2', 2),
        asn('C3a', 't3', 3),
        asn('C3b', 't4', 3),
      ],
      timeSlotIdsByLevel: const {
        '1': ['b1', 'b2', 'b3']
      },
      timeSlotIntervals: const {
        'b1': {'start': 480, 'end': 525},
        'b2': {'start': 525, 'end': 570},
        'b3': {'start': 570, 'end': 615},
      },
      roomIds: const [null],
      workingDays: 6,
      populationSize: 10,
      maxGenerations: 10,
      stagnationLimit: 5,
    );

    final out = await CspScheduler.run(input);
    expect(out.hardClashes, 0);

    final bySlot = <String, List<List<int>>>{};
    for (final g in out.chromosome) {
      final days = (g['day_block'] as List).cast<int>();
      for (int k = 1; k < days.length; k++) {
        expect(days[k], days[k - 1] + 1, reason: 'day blocks must be contiguous');
      }
      bySlot.putIfAbsent(g['time_slot_id'] as String, () => []).add(days);
    }

    expect(bySlot.length, 2, reason: 'courses should tile into the fewest periods');
    expect(bySlot.containsKey('b3'), isFalse, reason: 'latest period stays empty');
    for (final blocks in bySlot.values) {
      final all = blocks.expand((b) => b).toList()..sort();
      expect(all, [1, 2, 3, 4, 5, 6], reason: 'each used period tiles the full week');
    }
  });

  test('evening-shift class packs its own shift, not the morning slots', () async {
    final input = GaInput(
      assignments: [
        asn('C4', 't1', 4, cls: 'BS-EVE'),
        asn('C2', 't2', 2, cls: 'BS-EVE'),
      ],
      timeSlotIdsByLevel: const {
        '1': ['b1', 'b2', 'b3', 'b4']
      },
      timeSlotIntervals: const {
        'b1': {'start': 480, 'end': 525},
        'b2': {'start': 525, 'end': 570},
        'b3': {'start': 720, 'end': 765},
        'b4': {'start': 765, 'end': 810},
      },
      roomIds: const [null],
      workingDays: 6,
      populationSize: 10,
      maxGenerations: 10,
      stagnationLimit: 5,
      // Evening shift: morning slots b1/b2 are blocked for this class.
      shiftClassBlocks: const {
        'BS-EVE': ['b1', 'b2']
      },
    );

    final out = await CspScheduler.run(input);
    expect(out.hardClashes, 0);

    final slots = out.chromosome.map((g) => g['time_slot_id']).toSet();
    expect(slots, {'b3'},
        reason: 'both courses tile the earliest slot of the allowed shift');
    final all = out.chromosome
        .expand((g) => (g['day_block'] as List).cast<int>())
        .toList()
      ..sort();
    expect(all, [1, 2, 3, 4, 5, 6]);
  });
}
