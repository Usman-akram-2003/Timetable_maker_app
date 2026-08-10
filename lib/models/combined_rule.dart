class CombinedClassRule {
  final String id;
  final String courseId;
  final List<String> classIds;

  CombinedClassRule({
    required this.id,
    required this.courseId,
    required this.classIds,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'courseId': courseId,
      'classIds': classIds,
    };
  }

  factory CombinedClassRule.fromJson(Map<String, dynamic> json) {
    return CombinedClassRule(
      id: json['id'] as String,
      courseId: json['courseId'] as String,
      classIds: List<String>.from(json['classIds'] ?? []),
    );
  }
}
