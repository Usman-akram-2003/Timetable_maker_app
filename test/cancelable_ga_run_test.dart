import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/services/ga_engine.dart';
import 'package:timetable_maker_app/services/cancelable_ga_run.dart';

GaOutput _dummyInput = const GaOutput(
  chromosome: [], score: 0, hardClashes: 0, generationsRun: 1, message: 'ok', breakdown: {},
);

const _gaInput = GaInput(
  assignments: [], timeSlotIdsByLevel: {}, timeSlotIntervals: {}, roomIds: [],
  workingDays: 6, populationSize: 10, maxGenerations: 10, stagnationLimit: 5,
);

void main() {
  test('CancelableGaRun completes normally when not cancelled', () async {
    final run = CancelableGaRun();
    final result = await run.run((input) => _dummyInput, _gaInput);
    expect(result.message, 'ok');
  });

  test('CancelableGaRun.cancel() stops a busy worker and throws GaCancelled', () async {
    final run = CancelableGaRun();
    // A callback that spins forever — the only way out is cancel() killing
    // the isolate outright, which is exactly the behaviour under test.
    final future = run.run((input) {
      var x = 0;
      while (x >= 0) { x++; } // never exits on its own
      return _dummyInput; // unreachable — satisfies the return type
    }, _gaInput);

    // Give the isolate a moment to actually start spinning, then cancel.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    run.cancel();

    await expectLater(future, throwsA(isA<GaCancelled>()));
  });
}
