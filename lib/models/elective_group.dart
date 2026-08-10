class ElectiveEntry {
  final String id;
  final String courseId;
  final String courseName;
  final String teacherId;
  final String teacherName;
  final String? roomId;
  final String? roomLabel;

  ElectiveEntry({
    required this.id,
    required this.courseId,
    required this.courseName,
    required this.teacherId,
    required this.teacherName,
    this.roomId,
    this.roomLabel,
  });

  ElectiveEntry copyWith({String? id, String? courseId, String? courseName, String? teacherId, String? teacherName, String? roomId, String? roomLabel}) =>
      ElectiveEntry(id: id ?? this.id, courseId: courseId ?? this.courseId, courseName: courseName ?? this.courseName, teacherId: teacherId ?? this.teacherId, teacherName: teacherName ?? this.teacherName, roomId: roomId ?? this.roomId, roomLabel: roomLabel ?? this.roomLabel);

  Map<String, dynamic> toJson() => {'id': id, 'courseId': courseId, 'courseName': courseName, 'teacherId': teacherId, 'teacherName': teacherName, 'roomId': roomId, 'roomLabel': roomLabel};

  factory ElectiveEntry.fromJson(Map<String, dynamic> json) => ElectiveEntry(
      id: json['id'] as String, courseId: json['courseId'] as String, courseName: json['courseName'] as String,
      teacherId: json['teacherId'] as String, teacherName: json['teacherName'] as String,
      roomId: json['roomId'] as String?, roomLabel: json['roomLabel'] as String?);
}

class ElectiveGroup {
  final String id;
  final String timeSlotId;
  final List<String> classIds;
  final List<ElectiveEntry> entries;

  ElectiveGroup({required this.id, required this.timeSlotId, required this.classIds, required this.entries});

  ElectiveGroup copyWith({String? id, String? timeSlotId, List<String>? classIds, List<ElectiveEntry>? entries}) =>
      ElectiveGroup(id: id ?? this.id, timeSlotId: timeSlotId ?? this.timeSlotId, classIds: classIds ?? this.classIds, entries: entries ?? this.entries);

  Map<String, dynamic> toJson() => {'id': id, 'timeSlotId': timeSlotId, 'classIds': classIds, 'entries': entries.map((e) => e.toJson()).toList()};

  factory ElectiveGroup.fromJson(Map<String, dynamic> json) => ElectiveGroup(
      id: json['id'] as String, timeSlotId: json['timeSlotId'] as String,
      classIds: List<String>.from(json['classIds'] ?? []),
      entries: (json['entries'] as List? ?? []).map((e) => ElectiveEntry.fromJson(e as Map<String, dynamic>)).toList());
}