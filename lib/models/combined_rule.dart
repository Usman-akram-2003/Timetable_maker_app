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

/// Whether [classIdA] and [classIdB] are combined for [courseId] — directly
/// (both listed in one rule) or transitively, chained through a shared class
/// across separate rules for the same course (combine A+B in one rule, then
/// separately combine A+C in another, and B+C count as combined too — they
/// all share the same slot/teacher/room once addCombinedRule syncs them).
/// The single source of truth for this check — every clash/overlap check in
/// the app that needs to exempt combined siblings should call this instead
/// of re-deriving its own same-rule-only membership test.
bool combinedRulesLinkClasses(List<CombinedClassRule> rules, String courseId,
    String classIdA, String classIdB) {
  if (classIdA == classIdB) return true;
  final parent = <String, String>{};
  String find(String x) {
    parent.putIfAbsent(x, () => x);
    while (parent[x] != x) {
      parent[x] = parent[parent[x]!]!;
      x = parent[x]!;
    }
    return x;
  }

  for (final r in rules) {
    if (r.courseId != courseId || r.classIds.length < 2) continue;
    for (int i = 1; i < r.classIds.length; i++) {
      final rx = find(r.classIds[0]);
      final ry = find(r.classIds[i]);
      if (rx != ry) parent[rx] = ry;
    }
  }

  if (!parent.containsKey(classIdA) || !parent.containsKey(classIdB)) return false;
  return find(classIdA) == find(classIdB);
}
