// Batch-import resolver: reads every .xlsx on the Desktop, parses each with
// the SAME tested parser the app's Import Timetable dialog uses
// (TimetableGridImportService.parseDecoder, from
// lib/services/timetable_grid_import_core.dart), and replicates
// timetable_grid_import_screen.dart's _applyImport() resolution/dedup/
// creation logic bit-for-bit against an in-memory copy of the live dataset.
//
// This script NEVER touches Firestore. It only ever reads a seed JSON file
// (produced by ../node/fetch_and_backup.js) and, optionally, writes a
// finalized JSON file for ../node/apply_import.js to write for real.
//
// Usage:
//   dart run tool/batch_import/dart/resolve_import.dart --seed <backup.json>
//   dart run tool/batch_import/dart/resolve_import.dart --seed <backup.json> --write-finalized
//
// Flags:
//   --seed <path>        Required. The backup/seed JSON from fetch_and_backup.js.
//   --dir <path>         Desktop folder to scan for .xlsx files. Defaults to
//                         C:\Users\Admin\OneDrive\Desktop.
//   --write-finalized    Also write tool/batch_import/backups/finalized_<ts>.json.
//                         Without this flag, the run is dry — nothing is written.

import 'dart:convert';
import 'dart:io';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'package:timetable_maker_app/services/timetable_grid_import_core.dart';

const kIntermediate = 0;
const kBachelors = 1;

// ── Local mutable model types ───────────────────────────────────────────────
// Deliberately not importing lib/models/*.dart — keeps this tool decoupled
// from the Flutter app. Field shapes below match _saveData() in
// lib/viewmodels/data_entry_viewmodel.dart EXACTLY (verified by reading it
// directly, including the subtlety that the assignment's embedded course
// snapshot has no `level` field, unlike the top-level courses list entry).

class Teacher {
  String id, name, department;
  Teacher({required this.id, required this.name, required this.department});
  factory Teacher.fromJson(Map<String, dynamic> j) => Teacher(
      id: j['id'] as String, name: j['name'] as String, department: (j['department'] as String?) ?? '');
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'department': department};
}

class Course {
  String id, name, code;
  int creditHours, level;
  Course({required this.id, required this.name, required this.code, required this.creditHours, required this.level});
  factory Course.fromJson(Map<String, dynamic> j) => Course(
      id: j['id'] as String, name: j['name'] as String, code: j['code'] as String,
      creditHours: (j['creditHours'] as num).toInt(), level: (j['level'] as num).toInt());
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'code': code, 'creditHours': creditHours, 'level': level};
}

class Program {
  String id, name;
  int level;
  Program({required this.id, required this.name, required this.level});
  factory Program.fromJson(Map<String, dynamic> j) =>
      Program(id: j['id'] as String, name: j['name'] as String, level: (j['level'] as num).toInt());
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'level': level};
}

class ClassRec {
  String id, programId, name, shortCode;
  int level;
  ClassRec({required this.id, required this.programId, required this.name, required this.shortCode, required this.level});
  factory ClassRec.fromJson(Map<String, dynamic> j) => ClassRec(
      id: j['id'] as String, programId: j['programId'] as String, name: j['name'] as String,
      shortCode: j['shortCode'] as String, level: (j['level'] as num).toInt());
  Map<String, dynamic> toJson() =>
      {'id': id, 'programId': programId, 'name': name, 'shortCode': shortCode, 'level': level};
}

class RoomRec {
  String id, name;
  int type, capacity;
  RoomRec({required this.id, required this.name, required this.type, required this.capacity});
  factory RoomRec.fromJson(Map<String, dynamic> j) => RoomRec(
      id: j['id'] as String, name: j['name'] as String,
      type: (j['type'] as num?)?.toInt() ?? 0, capacity: (j['capacity'] as num?)?.toInt() ?? 0);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type, 'capacity': capacity};
}

class TimeSlotRec {
  String id, startTime, endTime;
  int period, level;
  bool hasFridayOverride;
  String? fridayStart, fridayEnd;
  TimeSlotRec({
    required this.id, required this.period, required this.startTime, required this.endTime,
    required this.level, this.hasFridayOverride = false, this.fridayStart, this.fridayEnd,
  });
  factory TimeSlotRec.fromJson(Map<String, dynamic> j) => TimeSlotRec(
      id: j['id'] as String, period: (j['period'] as num).toInt(),
      startTime: j['startTime'] as String, endTime: j['endTime'] as String,
      level: (j['level'] as num).toInt(),
      hasFridayOverride: (j['hasFridayOverride'] as bool?) ?? false,
      fridayStart: j['fridayStart'] as String?, fridayEnd: j['fridayEnd'] as String?);
  Map<String, dynamic> toJson() => {
        'id': id, 'period': period, 'startTime': startTime, 'endTime': endTime, 'level': level,
        'hasFridayOverride': hasFridayOverride, 'fridayStart': fridayStart, 'fridayEnd': fridayEnd,
      };
}

// Embedded snapshot shapes exactly matching _saveData()'s nested
// 'assignments' field — note course has NO level, unlike the top-level
// courses list.
class AssignmentRec {
  String id;
  Map<String, dynamic> teacher;    // {id, name, department}
  Map<String, dynamic> course;     // {id, name, code, creditHours}  — no level
  Map<String, dynamic> classModel; // {id, programId, name, shortCode, level}
  int startSlot, duration;
  String timeSlotId;
  List<int> customDays;
  String? roomId;
  bool autoAssigned;
  AssignmentRec({
    required this.id, required this.teacher, required this.course, required this.classModel,
    required this.startSlot, required this.duration, required this.timeSlotId,
    required this.customDays, this.roomId, required this.autoAssigned,
  });
  factory AssignmentRec.fromJson(Map<String, dynamic> j) => AssignmentRec(
      id: j['id'] as String,
      teacher: Map<String, dynamic>.from(j['teacher'] as Map),
      course: Map<String, dynamic>.from(j['course'] as Map),
      classModel: Map<String, dynamic>.from(j['classModel'] as Map),
      startSlot: (j['startSlot'] as num).toInt(), duration: (j['duration'] as num).toInt(),
      timeSlotId: j['timeSlotId'] as String,
      customDays: List<int>.from((j['customDays'] as List?) ?? const []),
      roomId: j['roomId'] as String?, autoAssigned: (j['autoAssigned'] as bool?) ?? false);
  Map<String, dynamic> toJson() => {
        'id': id, 'teacher': teacher, 'course': course, 'classModel': classModel,
        'startSlot': startSlot, 'duration': duration, 'timeSlotId': timeSlotId,
        'customDays': customDays, 'roomId': roomId, 'autoAssigned': autoAssigned,
      };
  List<int> get occupiedSlots =>
      customDays.isNotEmpty ? customDays : List.generate(duration, (i) => startSlot + i);
}

class ElectiveEntryRec {
  String id, courseId, courseName, teacherId, teacherName;
  String? roomId, roomLabel;
  ElectiveEntryRec({required this.id, required this.courseId, required this.courseName,
      required this.teacherId, required this.teacherName, this.roomId, this.roomLabel});
  factory ElectiveEntryRec.fromJson(Map<String, dynamic> j) => ElectiveEntryRec(
      id: j['id'] as String, courseId: j['courseId'] as String, courseName: j['courseName'] as String,
      teacherId: j['teacherId'] as String, teacherName: j['teacherName'] as String,
      roomId: j['roomId'] as String?, roomLabel: j['roomLabel'] as String?);
  Map<String, dynamic> toJson() => {'id': id, 'courseId': courseId, 'courseName': courseName,
      'teacherId': teacherId, 'teacherName': teacherName, 'roomId': roomId, 'roomLabel': roomLabel};
}

class ElectiveGroupRec {
  String id, timeSlotId;
  List<String> classIds;
  List<ElectiveEntryRec> entries;
  ElectiveGroupRec({required this.id, required this.timeSlotId, required this.classIds, required this.entries});
  factory ElectiveGroupRec.fromJson(Map<String, dynamic> j) => ElectiveGroupRec(
      id: j['id'] as String, timeSlotId: j['timeSlotId'] as String,
      classIds: List<String>.from((j['classIds'] as List?) ?? const []),
      entries: ((j['entries'] as List?) ?? const [])
          .map((e) => ElectiveEntryRec.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList());
  Map<String, dynamic> toJson() => {'id': id, 'timeSlotId': timeSlotId, 'classIds': classIds,
      'entries': entries.map((e) => e.toJson()).toList()};
}

// ── Mutable in-memory state, seeded from the live-data backup ──────────────

class ImportState {
  List<dynamic> departments;
  List<Teacher> teachers;
  List<Course> courses;
  List<Program> programs;
  List<ClassRec> classes;
  List<RoomRec> rooms;
  List<TimeSlotRec> timeslots;
  List<dynamic> timeSlotLocks;
  List<dynamic> combinedRules;
  List<ElectiveGroupRec> electiveGroups;
  List<dynamic> shiftRules;
  List<AssignmentRec> assignments;
  int workingDays;
  int _uidCounter = 0;

  ImportState({
    required this.departments, required this.teachers, required this.courses,
    required this.programs, required this.classes, required this.rooms,
    required this.timeslots, required this.timeSlotLocks, required this.combinedRules,
    required this.electiveGroups, required this.shiftRules, required this.assignments,
    required this.workingDays,
  });

  factory ImportState.fromSeed(Map<String, dynamic> seed) {
    final t = Map<String, dynamic>.from(seed['timetable'] as Map);
    final settings = Map<String, dynamic>.from((seed['settings'] as Map?) ?? const {});
    List<T> listOf<T>(String key, T Function(Map<String, dynamic>) fromJson) =>
        ((t[key] as List?) ?? const [])
            .map((e) => fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
    return ImportState(
      departments: List<dynamic>.from((t['departments'] as List?) ?? const []),
      teachers: listOf('teachers', Teacher.fromJson),
      courses: listOf('courses', Course.fromJson),
      programs: listOf('programs', Program.fromJson),
      classes: listOf('classes', ClassRec.fromJson),
      rooms: listOf('rooms', RoomRec.fromJson),
      timeslots: listOf('timeslots', TimeSlotRec.fromJson),
      timeSlotLocks: List<dynamic>.from((t['time_slot_locks'] as List?) ?? const []),
      combinedRules: List<dynamic>.from((t['combinedRules'] as List?) ?? const []),
      electiveGroups: listOf('electiveGroups', ElectiveGroupRec.fromJson),
      shiftRules: List<dynamic>.from((t['shiftRules'] as List?) ?? const []),
      assignments: listOf('assignments', AssignmentRec.fromJson),
      workingDays: (settings['workingDays'] as num?)?.toInt() ?? 6,
    );
  }

  Map<String, dynamic> toFinalizedJson() => {
        'departments': departments,
        'teachers': teachers.map((e) => e.toJson()).toList(),
        'courses': courses.map((e) => e.toJson()).toList(),
        'programs': programs.map((e) => e.toJson()).toList(),
        'classes': classes.map((e) => e.toJson()).toList(),
        'rooms': rooms.map((e) => e.toJson()).toList(),
        'timeslots': timeslots.map((e) => e.toJson()).toList(),
        'time_slot_locks': timeSlotLocks,
        'combinedRules': combinedRules,
        'electiveGroups': electiveGroups.map((e) => e.toJson()).toList(),
        'shiftRules': shiftRules,
        'assignments': assignments.map((e) => e.toJson()).toList(),
      };

  // Matches DataEntryViewModel._uid(): microsecond timestamp + a
  // process-local counter. Never persisted/compared against historical IDs,
  // so a different counter across runs is not a collision risk.
  String uid() {
    _uidCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}_$_uidCounter';
  }
}

// ── Report ───────────────────────────────────────────────────────────────

class FileReport {
  final String fileName;
  bool skippedTooSmall = false;
  String? fatalError;
  bool? isIntermediate;
  int periodsFound = 0;
  int teachersCreated = 0, coursesCreated = 0, programsCreated = 0;
  int classesCreated = 0, roomsCreated = 0, timeslotsCreated = 0, timeslotsRemoved = 0;
  int assignmentsBuilt = 0, assignmentsSkippedUnresolved = 0, assignmentsSkippedDuplicate = 0;
  int electiveGroupsBuilt = 0;
  final List<String> electiveAttribution = [];
  final List<String> parserWarnings = [];
  FileReport(this.fileName);
}

// ── _applyImport() replica ──────────────────────────────────────────────────
// Every rule below is cited against timetable_grid_import_screen.dart's
// _applyImport() — see tool/batch_import/README.md for the line-by-line
// mapping. Always simulates _mergeMode = true, _createTimeslots = true.

String makeCode(String subject) {
  final words = subject.trim().split(RegExp(r'\s+'));
  if (words.length == 1) return words[0].substring(0, words[0].length.clamp(0, 6)).toUpperCase();
  return words.map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join().substring(0, words.length.clamp(0, 5));
}

Teacher? findTeacher(List<Teacher> teachers, String name) {
  final target = name.toLowerCase().trim();
  for (final t in teachers) { if (t.name.toLowerCase().trim() == target) return t; }
  for (final t in teachers) { if (TimetableGridImportService.teacherNamesMatch(t.name, name)) return t; }
  return null;
}

Course? findCourse(List<Course> courses, String name, int level) {
  final code = makeCode(name);
  for (final c in courses) {
    if (c.level == level && c.code.toLowerCase() == code.toLowerCase()) return c;
  }
  for (final c in courses) {
    if (c.level == level && TimetableGridImportService.courseNamesMatch(c.name, name)) return c;
  }
  return null;
}

int parseMin(String t) {
  final p = t.split(':');
  if (p.length != 2) return 0;
  return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
}

// data_entry_viewmodel.dart renumberTimeSlotsChronologically().
void renumberChronologically(ImportState st, int level) {
  final levelSlots = st.timeslots.where((t) => t.level == level).toList()
    ..sort((a, b) => parseMin(a.startTime).compareTo(parseMin(b.startTime)));
  for (int i = 0; i < levelSlots.length; i++) {
    levelSlots[i].period = i + 1;
  }
}

void resolveOneFile(ImportState st, TimetableGridImportResult result, FileReport rpt) {
  final level = result.isIntermediate ? kIntermediate : kBachelors;
  rpt.isIntermediate = result.isIntermediate;
  rpt.periodsFound = result.periods.length;
  rpt.parserWarnings.addAll(result.warnings);

  // ── 1: Time slots (screen lines ~88-127) ──────────────────────────────────
  final existingStarts = st.timeslots.where((t) => t.level == level).map((t) => t.startTime).toSet();
  for (final p in result.periods) {
    if (!existingStarts.contains(p.startTime)) {
      final period = st.timeslots.where((t) => t.level == level).isEmpty
          ? 1
          : st.timeslots.where((t) => t.level == level).map((t) => t.period).reduce((a, b) => a > b ? a : b) + 1;
      st.timeslots.add(TimeSlotRec(id: st.uid(), period: period, startTime: p.startTime, endTime: p.endTime, level: level));
      rpt.timeslotsCreated++;
    }
  }
  final neededStarts = result.periods.map((p) => p.startTime).toSet();
  final stale = st.timeslots.where((ts) =>
      ts.level == level &&
      !neededStarts.contains(ts.startTime) &&
      !st.assignments.any((a) => a.timeSlotId == ts.id) &&
      !st.electiveGroups.any((eg) => eg.timeSlotId == ts.id)).toList();
  for (final ts in stale) { st.timeslots.remove(ts); rpt.timeslotsRemoved++; }
  renumberChronologically(st, level);

  final slotsByStart = {for (final ts in st.timeslots.where((t) => t.level == level)) ts.startTime: ts};
  TimeSlotRec? slotForPeriod(int periodIndex) =>
      periodIndex < result.periods.length ? slotsByStart[result.periods[periodIndex].startTime] : null;

  // ── 2: Teachers (screen lines ~108-118) ───────────────────────────────────
  for (final name in result.teacherNames) {
    if (findTeacher(st.teachers, name) == null) {
      st.teachers.add(Teacher(id: st.uid(), name: name.trim(), department: ''));
      rpt.teachersCreated++;
    }
  }

  // ── 3: Courses (screen lines ~123-149) ────────────────────────────────────
  final subjectCreditHours = <String, int>{};
  for (final draft in result.assignments) {
    final d = draft.days;
    if (d == null) continue;
    final code = makeCode(draft.subjectName).toLowerCase();
    final existing = subjectCreditHours[code];
    if (existing == null || d.length < existing) subjectCreditHours[code] = d.length;
  }
  for (final subject in result.subjectNames) {
    if (findCourse(st.courses, subject, level) == null) {
      final code = makeCode(subject);
      st.courses.add(Course(
          id: st.uid(), name: subject.trim(), code: code,
          creditHours: subjectCreditHours[code.toLowerCase()] ?? st.workingDays, level: level));
      rpt.coursesCreated++;
    }
  }

  // ── 4: Programs + classes (screen lines ~154-183) ─────────────────────────
  for (final cls in result.classes) {
    var prog = st.programs.where((p) => p.name.toLowerCase() == cls.program.toLowerCase() && p.level == level).firstOrNull;
    if (prog == null) {
      prog = Program(id: st.uid(), name: cls.program.trim(), level: level);
      st.programs.add(prog);
      rpt.programsCreated++;
    }
    final exists = st.classes.any((c) => c.programId == prog!.id && c.name.toLowerCase() == cls.section.trim().toLowerCase());
    if (!exists) {
      st.classes.add(ClassRec(
          id: st.uid(), programId: prog.id, name: cls.section.trim(),
          shortCode: '${prog.name}-${cls.section.trim()}', level: level));
      rpt.classesCreated++;
    }
  }

  // ── 5: Rooms (screen lines ~188-198) ──────────────────────────────────────
  for (final roomNo in result.roomNumbers) {
    if (roomNo.isEmpty) continue;
    final exists = st.rooms.any((r) => r.name.toLowerCase() == roomNo.toLowerCase());
    if (!exists) { st.rooms.add(RoomRec(id: st.uid(), name: roomNo, type: 0, capacity: 0)); rpt.roomsCreated++; }
  }

  // ── 6: Assignments (screen lines ~203-280) ────────────────────────────────
  bool sameDays(List<int> a, List<int>? b) {
    final bl = b ?? const <int>[];
    return a.length == bl.length && a.toSet().containsAll(bl);
  }
  for (final draft in result.assignments) {
    final teacher = findTeacher(st.teachers, draft.teacherName);
    final course = findCourse(st.courses, draft.subjectName, level);
    if (teacher == null || course == null) { rpt.assignmentsSkippedUnresolved++; continue; }

    final progIds = st.programs
        .where((p) => p.name.toLowerCase() == draft.programName.toLowerCase() && p.level == level)
        .map((p) => p.id).toSet();
    final section = draft.className.contains(' - ') ? draft.className.split(' - ').last : '';
    // section can be empty (files with no per-row Semester column) —
    // c.shortCode.contains('') is vacuously true for every class in the
    // program, so an empty section must skip that check entirely (real
    // bug found via two actual files: BS III's classless assignments were
    // silently attaching to BS I's "Chemistry-1" class instead of BS III's
    // own). Fixed identically in timetable_grid_import_screen.dart.
    final classModel = st.classes.where((c) =>
        progIds.contains(c.programId) &&
        ((section.isNotEmpty && c.shortCode.toLowerCase().contains(section.toLowerCase())) ||
         c.name.toLowerCase() == section.toLowerCase())).firstOrNull;
    if (classModel == null) { rpt.assignmentsSkippedUnresolved++; continue; }

    final slot = slotForPeriod(draft.periodIndex);
    if (slot == null) { rpt.assignmentsSkippedUnresolved++; continue; }

    final room = draft.roomNo.isNotEmpty
        ? st.rooms.where((r) => r.name == draft.roomNo).firstOrNull : null;

    final explicitDays = draft.days;
    final alreadyExists = st.assignments.any((a) =>
        a.teacher['id'] == teacher.id &&
        a.course['id'] == course.id &&
        a.classModel['id'] == classModel.id &&
        a.timeSlotId == slot.id &&
        sameDays(a.customDays, explicitDays));
    if (alreadyExists) { rpt.assignmentsSkippedDuplicate++; continue; }

    st.assignments.add(AssignmentRec(
      id: st.uid(),
      teacher: {'id': teacher.id, 'name': teacher.name, 'department': teacher.department},
      course: {'id': course.id, 'name': course.name, 'code': course.code, 'creditHours': course.creditHours},
      classModel: {'id': classModel.id, 'programId': classModel.programId, 'name': classModel.name,
          'shortCode': classModel.shortCode, 'level': classModel.level},
      startSlot: (explicitDays != null && explicitDays.isNotEmpty) ? explicitDays.first : 1,
      duration: (explicitDays != null && explicitDays.isNotEmpty) ? explicitDays.length : course.creditHours.clamp(1, st.workingDays),
      timeSlotId: slot.id,
      customDays: explicitDays ?? const [],
      roomId: room?.id,
      autoAssigned: true,
    ));
    rpt.assignmentsBuilt++;
  }

  // ── 7: Elective groups (screen lines ~349-380) — scoped by program+level,
  // matching the assignment loop above: two different Intermediate files
  // can produce the same section labels (e.g. both "Arts-I…" and
  // "Arts-II…" recovering "A0"/"A1"/"A2" from embedded row markers), and
  // matching on section text alone let an elective from one file attach to
  // the OTHER file's same-named class.
  for (final draft in result.electives) {
    final slot = slotForPeriod(draft.periodIndex);
    if (slot == null) continue;

    final classIds = <String>{};
    final resolvedNames = <String>[];
    for (final className in draft.classNames) {
      final hasSection = className.contains(' - ');
      final progName = hasSection ? className.substring(0, className.lastIndexOf(' - ')) : className;
      final section = hasSection ? className.split(' - ').last : '';

      final egProgIds = st.programs
          .where((p) => p.name.toLowerCase() == progName.toLowerCase() && p.level == level)
          .map((p) => p.id).toSet();

      final cls = st.classes.where((c) =>
          egProgIds.contains(c.programId) &&
          ((section.isNotEmpty && c.shortCode.toLowerCase().contains(section.toLowerCase())) ||
           c.name.toLowerCase() == section.toLowerCase())).firstOrNull;
      if (cls != null) { classIds.add(cls.id); resolvedNames.add('${cls.shortCode} (wanted "$className")'); }
    }
    if (classIds.isEmpty) continue;

    final entries = <ElectiveEntryRec>[];
    for (final opt in draft.entries) {
      final teacher = findTeacher(st.teachers, opt.teacherName);
      final course = findCourse(st.courses, opt.subjectName, level);
      if (teacher == null || course == null) continue;
      final room = opt.roomNo.isNotEmpty ? st.rooms.where((r) => r.name == opt.roomNo).firstOrNull : null;
      entries.add(ElectiveEntryRec(id: st.uid(), courseId: course.id, courseName: course.name,
          teacherId: teacher.id, teacherName: teacher.name, roomId: room?.id, roomLabel: room?.name));
    }
    if (entries.isEmpty) continue;

    final alreadyExists = st.electiveGroups.any((g) =>
        g.timeSlotId == slot.id &&
        g.classIds.toSet().containsAll(classIds) && classIds.containsAll(g.classIds.toSet()) &&
        g.entries.length == entries.length &&
        g.entries.every((e) => entries.any((ne) => ne.courseId == e.courseId && ne.teacherId == e.teacherId)));
    if (alreadyExists) continue;

    st.electiveGroups.add(ElectiveGroupRec(id: st.uid(), timeSlotId: slot.id, classIds: classIds.toList(), entries: entries));
    rpt.electiveGroupsBuilt++;
    rpt.electiveAttribution.add('P${draft.periodIndex} → ${resolvedNames.join(", ")}');
  }
}

// ── countClashes() replica (data_entry_viewmodel.dart lines ~2664-2739) ────

List<AssignmentRec> combinedAssignments(ImportState st) {
  final list = List<AssignmentRec>.from(st.assignments);
  for (final eg in st.electiveGroups) {
    for (final entry in eg.entries) {
      for (final classId in eg.classIds) {
        final cls = st.classes.where((c) => c.id == classId).firstOrNull;
        list.add(AssignmentRec(
          id: 'elec_${eg.id}_${entry.id}_$classId',
          teacher: {'id': entry.teacherId, 'name': entry.teacherName, 'department': ''},
          course: {'id': entry.courseId, 'name': entry.courseName, 'code': '?',
              'creditHours': st.courses.where((c) => c.id == entry.courseId).firstOrNull?.creditHours ?? 3},
          classModel: {'id': cls?.id ?? '', 'programId': cls?.programId ?? '', 'name': cls?.name ?? '?',
              'shortCode': cls?.shortCode ?? '?', 'level': cls?.level ?? kIntermediate},
          startSlot: 1,
          duration: st.courses.where((c) => c.id == entry.courseId).firstOrNull?.creditHours ?? 3,
          timeSlotId: eg.timeSlotId,
          customDays: const [],
          roomId: entry.roomId,
          autoAssigned: true,
        ));
      }
    }
  }
  return list;
}

int countClashes(ImportState st) {
  final aList = combinedAssignments(st);
  final slotBounds = {for (final t in st.timeslots) t.id: (s: parseMin(t.startTime), e: parseMin(t.endTime))};
  bool slotsOverlap(String a, String b) {
    if (a == b) return true;
    final sa = slotBounds[a], sb = slotBounds[b];
    if (sa == null || sb == null) return false;
    return sa.s < sb.e && sb.s < sa.e;
  }
  final byTs = <String, List<AssignmentRec>>{};
  for (final a in aList) { byTs.putIfAbsent(a.timeSlotId, () => []).add(a); }
  final tsIds = byTs.keys.toList();
  final validRoomIds = {for (final r in st.rooms) r.id};

  var count = 0;
  void checkPair(AssignmentRec a, AssignmentRec b) {
    final shared = a.occupiedSlots.toSet().intersection(b.occupiedSlots.toSet());
    if (shared.isEmpty) return;
    final hasRoomA = a.roomId != null && a.roomId!.isNotEmpty;
    final hasRoomB = b.roomId != null && b.roomId!.isNotEmpty;
    if ((a.teacher['id'] != '' && a.teacher['id'] == b.teacher['id']) ||
        a.classModel['id'] == b.classModel['id'] ||
        (hasRoomA && hasRoomB && a.roomId == b.roomId && validRoomIds.contains(a.roomId))) {
      count++;
    }
  }
  for (int ti = 0; ti < tsIds.length; ti++) {
    final bucketA = byTs[tsIds[ti]]!;
    for (int tj = ti; tj < tsIds.length; tj++) {
      if (!slotsOverlap(tsIds[ti], tsIds[tj])) continue;
      if (ti == tj) {
        for (int i = 0; i < bucketA.length; i++) {
          for (int j = i + 1; j < bucketA.length; j++) { checkPair(bucketA[i], bucketA[j]); }
        }
      } else {
        final bucketB = byTs[tsIds[tj]]!;
        for (final a in bucketA) { for (final b in bucketB) { checkPair(a, b); } }
      }
    }
  }
  return count;
}

// ── Main ─────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  String? seedPath;
  String desktopDir = r'C:\Users\Admin\OneDrive\Desktop';
  var writeFinalized = false;

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--seed': seedPath = args[++i]; break;
      case '--dir': desktopDir = args[++i]; break;
      case '--write-finalized': writeFinalized = true; break;
    }
  }
  if (seedPath == null) {
    stderr.writeln('Usage: dart run resolve_import.dart --seed <backup.json> [--dir <folder>] [--write-finalized]');
    exit(1);
  }

  final seed = jsonDecode(await File(seedPath).readAsString()) as Map<String, dynamic>;
  final st = ImportState.fromSeed(seed);
  print('Seed loaded: ${st.teachers.length} teachers, ${st.courses.length} courses, '
      '${st.programs.length} programs, ${st.classes.length} classes, ${st.rooms.length} rooms, '
      '${st.timeslots.length} timeslots, ${st.assignments.length} assignments, '
      '${st.electiveGroups.length} elective groups. workingDays=${st.workingDays}');

  final dir = Directory(desktopDir);
  final files = dir.listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.xlsx'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('\nDiscovered ${files.length} .xlsx file(s) in $desktopDir:');
  for (final f in files) { print('  - ${f.uri.pathSegments.last}'); }

  final reports = <FileReport>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final rpt = FileReport(name);
    reports.add(rpt);
    print('\n── $name ──');

    final bytes = await f.readAsBytes();
    // OneDrive Files-on-Demand can leave a cloud-only placeholder — a real
    // .xlsx is never this small.
    if (bytes.length < 2000) {
      rpt.skippedTooSmall = true;
      print('  SKIPPED: only ${bytes.length} bytes — likely a OneDrive placeholder, not downloaded locally.');
      continue;
    }

    try {
      final decoder = SpreadsheetDecoder.decodeBytes(bytes, update: false);
      final result = await TimetableGridImportService.parseDecoder(decoder, name, (_, __) {});
      resolveOneFile(st, result, rpt);
      print('  Level: ${rpt.isIntermediate! ? "Intermediate" : "Bachelors"}   Periods: ${rpt.periodsFound}');
      print('  Created — teachers:${rpt.teachersCreated} courses:${rpt.coursesCreated} '
          'programs:${rpt.programsCreated} classes:${rpt.classesCreated} rooms:${rpt.roomsCreated} '
          'timeslots:${rpt.timeslotsCreated} (removed stale:${rpt.timeslotsRemoved})');
      print('  Assignments — built:${rpt.assignmentsBuilt} '
          'skipped-unresolved:${rpt.assignmentsSkippedUnresolved} '
          'skipped-duplicate:${rpt.assignmentsSkippedDuplicate}');
      if (rpt.electiveGroupsBuilt > 0) {
        print('  Elective groups built: ${rpt.electiveGroupsBuilt}');
        for (final line in rpt.electiveAttribution) { print('    $line'); }
      }
      if (rpt.parserWarnings.isNotEmpty) {
        print('  Parser warnings (${rpt.parserWarnings.length}):');
        for (final w in rpt.parserWarnings.take(10)) { print('    $w'); }
      }
    } catch (e, st2) {
      rpt.fatalError = e.toString();
      print('  ERROR (file skipped, rest of batch continues): $e');
      if (Platform.environment['DEBUG'] == '1') print(st2);
    }
  }

  final clashCount = countClashes(st);
  print('\n════════════════════════════════════════════════════════');
  print('SUMMARY');
  print('  Files processed: ${reports.length}   '
      'Skipped (too small): ${reports.where((r) => r.skippedTooSmall).length}   '
      'Errored: ${reports.where((r) => r.fatalError != null).length}');
  print('  Final state — teachers:${st.teachers.length} courses:${st.courses.length} '
      'programs:${st.programs.length} classes:${st.classes.length} rooms:${st.rooms.length} '
      'timeslots:${st.timeslots.length} assignments:${st.assignments.length} '
      'electiveGroups:${st.electiveGroups.length}');
  print('  Total clash count (countClashes() replica, includes electives): $clashCount');
  print('════════════════════════════════════════════════════════');

  if (!writeFinalized) {
    print('\nDry run only — nothing written. Re-run with --write-finalized once this '
        'summary looks right, then apply with node apply_import.js --confirm.');
    return;
  }

  final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
  final outDir = Directory('tool/batch_import/backups');
  await outDir.create(recursive: true);
  final outFile = File('${outDir.path}/finalized_$ts.json');
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(st.toFinalizedJson()));
  print('\nWrote finalized state to: ${outFile.path}');
  print('Apply it with:\n'
      '  node tool/batch_import/node/apply_import.js --key <sa.json> --finalized ${outFile.path} --confirm');
}
