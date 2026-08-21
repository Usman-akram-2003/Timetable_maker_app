import 'package:flutter_test/flutter_test.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'package:timetable_maker_app/models/assignment.dart';
import 'package:timetable_maker_app/models/class_model.dart';
import 'package:timetable_maker_app/models/course.dart';
import 'package:timetable_maker_app/models/education_level.dart';
import 'package:timetable_maker_app/models/room.dart';
import 'package:timetable_maker_app/models/teacher.dart';
import 'package:timetable_maker_app/models/time_slot.dart';
import 'package:timetable_maker_app/services/timetable_grid_import_core.dart';
import 'package:timetable_maker_app/viewmodels/allocator_viewmodel.dart';

void main() {
  // Proves the Class-wise Excel export is genuinely round-trippable through
  // TimetableGridImportService — not just visually similar to it — by
  // building an export from known assignments, decoding the bytes with the
  // same spreadsheet_decoder the import screen uses, and feeding that
  // through the real parser.
  test('Class-wise export round-trips through the grid importer', () async {
    final teacher = Teacher(id: 't1', name: 'Dr. Muhammad Tahir', department: 'Science');
    final course = Course(
        id: 'c1', name: 'Mathematics', code: 'MATH101',
        creditHours: 6, level: EducationLevel.intermediate);
    final classModel = ClassModel(
        id: 'cl1', programId: 'p1', name: 'C5',
        shortCode: 'ICS Part1-C5', level: EducationLevel.intermediate);
    final room = Room(id: 'r1', name: '12', type: RoomType.room);
    // The importer's header-row detector only trusts a row once it finds 3+
    // period-shaped time cells in it — a single period column (a real but
    // degenerate timetable) would never be recognised as a header at all.
    final timeSlots = [
      TimeSlot(id: 'ts1', period: 1, startTime: '08:00', endTime: '08:40', level: EducationLevel.intermediate),
      TimeSlot(id: 'ts2', period: 2, startTime: '08:40', endTime: '09:20', level: EducationLevel.intermediate),
      TimeSlot(id: 'ts3', period: 3, startTime: '09:20', endTime: '10:00', level: EducationLevel.intermediate),
    ];
    final timeSlot = timeSlots.first;

    // Full working-week assignment — the case this export guarantees
    // round-trips (see the known-gap note on _classWiseCellText).
    final assignment = Assignment(
      id: 'a1', teacher: teacher, course: course, classModel: classModel,
      startSlot: 1, duration: 6, timeSlotId: timeSlot.id, roomId: room.id,
    );

    final vm = AllocatorViewModel();
    vm.validateAndApply([assignment], timeSlots, rooms: [room]);

    final bytes = vm.buildScheduleBytes(
      format: ExportFormat.excel,
      type: ExportType.studentWise,
      timeSlots: timeSlots,
      rooms: [room],
      classes: [classModel],
      workingDays: 6,
    );

    final decoder = SpreadsheetDecoder.decodeBytes(bytes);
    final result = await TimetableGridImportService.parseDecoder(
        decoder, 'roundtrip_test.xlsx', (progress, msg) {});

    expect(result.assignments, isNotEmpty,
        reason: 'export produced a grid the importer could not read any assignment back out of');
    final parsed = result.assignments.first;
    expect(parsed.teacherName, teacher.name);
    expect(parsed.subjectName, course.name);
    expect(parsed.roomNo, room.name);
    expect(parsed.className, contains('C5'));
  });
}
