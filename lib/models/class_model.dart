import 'education_level.dart';

/// A program group e.g. "BS Computer Science", "1st Year Science"
class ProgramGroup {
  final String id;
  final String name; // e.g. "BS Computer Science", "1st Year General"
  final EducationLevel level;

  ProgramGroup({required this.id, required this.name, required this.level});
}

/// A specific class/section within a program
/// e.g. "BS CS Semester-I" inside "BS Computer Science"
class ClassModel {
  final String id;
  final String programId; // parent program group
  final String name;      // e.g. "Semester-I", "Section A"
  final String shortCode; // auto-generated or user-set
  final EducationLevel level;

  ClassModel({
    required this.id,
    required this.programId,
    required this.name,
    required this.shortCode,
    required this.level,
  });

  String get fullName => name;

  @override
  bool operator ==(Object other) => other is ClassModel && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
