import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/models/assignment.dart';
import 'package:timetable_maker_app/models/class_model.dart';
import 'package:timetable_maker_app/models/course.dart';
import 'package:timetable_maker_app/models/education_level.dart';
import 'package:timetable_maker_app/models/teacher.dart';
import 'package:timetable_maker_app/models/time_slot.dart';
import 'package:timetable_maker_app/viewmodels/allocator_viewmodel.dart';

void main() {
  // Two different Bachelor courses, two different teachers, same class,
  // same time slot/day — the user's explicit new rule: this is an allowed
  // parallel session, not a clash. Same scenario at Intermediate level, or
  // with the same teacher on both, must still clash exactly as before.
  final timeSlot = TimeSlot(
      id: 'ts1', period: 1, startTime: '08:00', endTime: '09:00',
      level: EducationLevel.bachelors);

  ClassModel classFor(EducationLevel level) => ClassModel(
      id: 'cl1', programId: 'p1', name: 'A', shortCode: 'BS CS-A', level: level);

  Assignment asg(String id, Teacher t, Course c, ClassModel cls) => Assignment(
      id: id, teacher: t, course: c, classModel: cls,
      startSlot: 1, duration: 6, timeSlotId: timeSlot.id);

  test('Bachelor: 2 different teachers/courses, same class+time — no clash', () {
    final cls = classFor(EducationLevel.bachelors);
    final t1 = Teacher(id: 't1', name: 'Dr. A');
    final t2 = Teacher(id: 't2', name: 'Dr. B');
    final c1 = Course(id: 'c1', name: 'Math', code: 'MATH', level: EducationLevel.bachelors);
    final c2 = Course(id: 'c2', name: 'Physics', code: 'PHY', level: EducationLevel.bachelors);
    final a = asg('a1', t1, c1, cls);
    final b = asg('a2', t2, c2, cls);

    final vm = AllocatorViewModel();
    final ok = vm.validateAndApply([a, b], [timeSlot]);
    expect(ok, isTrue, reason: vm.lastError ?? 'expected no clash');
    expect(vm.lastError, isNull);
  });

  test('Intermediate: same scenario still clashes — rule is Bachelor-only', () {
    final cls = classFor(EducationLevel.intermediate);
    final t1 = Teacher(id: 't1', name: 'Dr. A');
    final t2 = Teacher(id: 't2', name: 'Dr. B');
    final c1 = Course(id: 'c1', name: 'Math', code: 'MATH', level: EducationLevel.intermediate);
    final c2 = Course(id: 'c2', name: 'Physics', code: 'PHY', level: EducationLevel.intermediate);
    final a = asg('a1', t1, c1, cls);
    final b = asg('a2', t2, c2, cls);

    final vm = AllocatorViewModel();
    final ok = vm.validateAndApply([a, b], [timeSlot]);
    expect(ok, isFalse);
    expect(vm.lastError, contains('Class clash'));
  });

  test('Bachelor, same teacher on both — still a real teacher clash', () {
    final cls = classFor(EducationLevel.bachelors);
    final t1 = Teacher(id: 't1', name: 'Dr. A');
    final c1 = Course(id: 'c1', name: 'Math', code: 'MATH', level: EducationLevel.bachelors);
    final c2 = Course(id: 'c2', name: 'Physics', code: 'PHY', level: EducationLevel.bachelors);
    final a = asg('a1', t1, c1, cls);
    final b = asg('a2', t1, c2, cls);

    final vm = AllocatorViewModel();
    final ok = vm.validateAndApply([a, b], [timeSlot]);
    expect(ok, isFalse);
    expect(vm.lastError, contains('Teacher clash'));
  });
}
