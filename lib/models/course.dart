import 'education_level.dart';

class Course {
  final String id;
  final String name;
  final String code;       // e.g. "CS-101"
  final int creditHours;   // 1–6: number of lectures per week
  final EducationLevel level; // bachelors or intermediate

  Course({
    required this.id,
    required this.name,
    required this.code,
    this.creditHours = 3,
    this.level = EducationLevel.bachelors,
  });

  @override
  bool operator ==(Object other) => other is Course && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
