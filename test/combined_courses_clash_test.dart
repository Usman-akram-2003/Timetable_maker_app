// Regression test for the "combining a second teacher group clashes with an
// unrelated course" bug: addCombinedRule()'s force-sync used to overwrite a
// class's slot to match the group anchor with zero regard for whatever else
// that class already had booked there. See _combinedMoveClashes in
// data_entry_viewmodel.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/viewmodels/data_entry_viewmodel.dart';
import 'package:timetable_maker_app/models/education_level.dart';
import 'package:timetable_maker_app/models/combined_rule.dart';

void main() {
  test('combining a second teacher group never force-moves a class onto a slot '
      'already holding a different course for it', () {
    final vm = DataEntryViewModel();

    vm.addProgram('BS CS', EducationLevel.bachelors);
    final prog = vm.programs.first;
    for (final n in ['C1', 'C2', 'C3', 'C4']) {
      vm.addClass(prog.id, n);
    }
    final byClassName = (String n) => vm.classes.firstWhere((c) => c.name == n);
    final c1 = byClassName('C1'), c2 = byClassName('C2');
    final c3 = byClassName('C3'), c4 = byClassName('C4');

    for (final n in ['Teacher A', 'Teacher B', 'Teacher C']) {
      vm.addTeacher(n);
    }
    final byTeacherName = (String n) => vm.teachers.firstWhere((t) => t.name == n);
    final tA = byTeacherName('Teacher A'), tB = byTeacherName('Teacher B'),
        tC = byTeacherName('Teacher C');

    vm.addCourse('Islamiyat', 'ISL', creditHours: 2, level: EducationLevel.bachelors);
    vm.addCourse('Physics', 'PHY', creditHours: 2, level: EducationLevel.bachelors);
    final islamiyat = vm.courses.firstWhere((c) => c.code == 'ISL');
    final physics = vm.courses.firstWhere((c) => c.code == 'PHY');

    vm.addTimeSlot('08:00', '09:00', EducationLevel.bachelors);
    vm.addTimeSlot('10:00', '11:00', EducationLevel.bachelors); // distinct clock time
    final s1 = vm.timeSlots[0];
    final s3 = vm.timeSlots[1];

    // Group 1: C1 + C2 already share Islamiyat/Teacher A at S1, days 1-2 —
    // combining them is a formality (already in sync).
    vm.addAssignment(teacher: tA, course: islamiyat, classModel: c1, startSlot: 1, duration: 2, timeSlotId: s1.id);
    vm.addAssignment(teacher: tA, course: islamiyat, classModel: c2, startSlot: 1, duration: 2, timeSlotId: s1.id);

    // Group 2: C3 already has Islamiyat/Teacher B at S1 (becomes the anchor).
    // C4 has Islamiyat/Teacher B at S3, but ALSO a separate Physics class
    // sitting at S1 days 1-2 — the real clash the old force-sync ignored.
    vm.addAssignment(teacher: tB, course: islamiyat, classModel: c3, startSlot: 1, duration: 2, timeSlotId: s1.id);
    vm.addAssignment(teacher: tB, course: islamiyat, classModel: c4, startSlot: 1, duration: 2, timeSlotId: s3.id);
    vm.addAssignment(teacher: tC, course: physics, classModel: c4, startSlot: 1, duration: 2, timeSlotId: s1.id);

    vm.addCombinedRule(CombinedClassRule(id: 'r1', courseId: islamiyat.id, classIds: [c1.id, c2.id]));
    final log2 = vm.addCombinedRule(
        CombinedClassRule(id: 'r2', courseId: islamiyat.id, classIds: [c3.id, c4.id]));

    final c4Islamiyat = vm.assignments
        .firstWhere((a) => a.classModel.id == c4.id && a.course.id == islamiyat.id);
    expect(c4Islamiyat.timeSlotId, s3.id,
        reason: 'C4 must stay put, not get force-moved into its own Physics slot');
    expect(log2.any((l) => l.startsWith('Skipped')), isTrue);
    expect(vm.countClashes(), 0);
  });
}
