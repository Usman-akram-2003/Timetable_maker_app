// ignore_for_file: avoid_print
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/services/ga_engine.dart';

void main() {
  test('Scale test with 2000 assignments', () async {
    print('Generating 2000 assignments for scale test...');
    
    final rand = Random();
    final assignments = <Map<String, dynamic>>[];
    final timeSlotIdsByLevel = <String, List<String>>{
      '0': List.generate(6, (i) => 'ts_b_$i'),
      '1': List.generate(6, (i) => 'ts_i_$i'),
    };
    
    final timeSlotIntervals = <String, Map<String, int>>{};
    for (int i = 0; i < 6; i++) {
      timeSlotIntervals['ts_b_$i'] = {'start': 480 + (i * 60), 'end': 540 + (i * 60)};
      timeSlotIntervals['ts_i_$i'] = {'start': 480 + (i * 60), 'end': 540 + (i * 60)};
    }
    
    final roomIds = List.generate(20, (i) => 'room_$i');
    
    for (int i = 0; i < 2000; i++) {
      final level = rand.nextInt(2);
      assignments.add({
        'teacher_id': 'teacher_${rand.nextInt(50)}',
        'course_id': 'course_${rand.nextInt(100)}',
        'discipline_id': 'class_${rand.nextInt(100)}',
        'section': 'A',
        'room_id': roomIds[rand.nextInt(roomIds.length)],
        'level': level,
        'credit_hours': 3, // Each assignment needs 3 days
        'locked_start_day': null,
        'locked_time_slot_id': null,
      });
    }
    
    final input = GaInput(
      assignments: assignments,
      timeSlotIdsByLevel: timeSlotIdsByLevel,
      timeSlotIntervals: timeSlotIntervals,
      roomIds: roomIds,
      lockedSlots: [],
      workingDays: 5, // Mon-Fri
      populationSize: 50,
      maxGenerations: 50, // Limit to 50 generations for a quick test
      stagnationLimit: 10,
    );

    print('Starting GA Engine...');
    final sw = Stopwatch()..start();
    
    try {
      final output = await GaEngine.run(input);
      sw.stop();
      print('=======================================');
      print('GA Scale Test Complete!');
      print('Time elapsed: ${sw.elapsedMilliseconds} ms');
      print('Total Assignments Scheduled: 2000');
      print('Total Time Slots (Days * Periods): ${5 * 6}');
      print('Generations Run: ${output.generationsRun}');
      print('Hard Clashes Remaining: ${output.hardClashes}');
      print('Message: ${output.message}');
      print('=======================================');
    } catch (e, st) {
      fail('GA CRASHED: $e\n$st');
    }
    // GA has a 60s wall-clock cap, so the default 30s test timeout can never
    // let a 2000-assignment run finish.
  }, timeout: const Timeout(Duration(minutes: 3)));
}
