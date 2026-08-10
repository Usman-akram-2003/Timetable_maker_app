import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/viewmodels/data_entry_viewmodel.dart';

void main() {
  test('normalizeDayBlock rebuilds the corrupted startSlot-3/duration-6 case',
      () {
    // Real corrupted record: startSlot 3 + duration 6 with workingDays 6
    // yields days [3,4,5,6,7,8] — must normalize to the full week.
    expect(
        DataEntryViewModel.normalizeDayBlock(
            days: [3, 4, 5, 6, 7, 8],
            startSlot: 3,
            duration: 6,
            workingDays: 6),
        [1, 2, 3, 4, 5, 6]);
  });

  test('normalizeDayBlock dedupes and keeps enough in-range days', () {
    expect(
        DataEntryViewModel.normalizeDayBlock(
            days: [1, 2, 2, 3], startSlot: 1, duration: 3, workingDays: 6),
        [1, 2, 3]);
  });

  test('normalizeDayBlock rebuilds a clamped block when days are empty', () {
    expect(
        DataEntryViewModel.normalizeDayBlock(
            days: [], startSlot: 9, duration: 3, workingDays: 6),
        [4, 5, 6]);
  });
}
