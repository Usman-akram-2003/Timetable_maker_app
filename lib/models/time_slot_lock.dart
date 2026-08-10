import 'education_level.dart';

class TimeSlotLock {
  final String id;
  final String courseId;
  final String courseCode; // For display purposes
  final String? classId;
  final String? className; // For display purposes
  final EducationLevel level;
  final String timeSlotId;
  final String timeSlotLabel; // For display purposes

  TimeSlotLock({
    required this.id,
    required this.courseId,
    required this.courseCode,
    this.classId,
    this.className,
    required this.level,
    required this.timeSlotId,
    required this.timeSlotLabel,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'courseId': courseId,
    'courseCode': courseCode,
    'classId': classId,
    'className': className,
    'level': level.index,
    'timeSlotId': timeSlotId,
    'timeSlotLabel': timeSlotLabel,
  };

  factory TimeSlotLock.fromJson(Map<String, dynamic> json) => TimeSlotLock(
    id: json['id'],
    courseId: json['courseId'],
    courseCode: json['courseCode'],
    classId: json['classId'],
    className: json['className'],
    level: EducationLevel.values[json['level']],
    timeSlotId: json['timeSlotId'],
    timeSlotLabel: json['timeSlotLabel'] ?? 'Locked Slot',
  );
}
