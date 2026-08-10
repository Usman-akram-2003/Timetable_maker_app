enum ShiftType { morning, evening }

/// Assigns a specific Bachelors class to a Morning or Evening shift.
/// Morning = Bachelors P1-P3 (08:00-11:00)
/// Evening = Bachelors P4-P6 (11:00-14:00)
class ShiftRule {
  final String id;
  final String classId;   // ClassModel.id
  final String className; // display only — not used for logic
  final ShiftType shift;

  const ShiftRule({
    required this.id,
    required this.classId,
    required this.className,
    required this.shift,
  });

  Map<String, dynamic> toJson() => {
    'id':        id,
    'classId':   classId,
    'className': className,
    'shift':     shift.index,
  };

  factory ShiftRule.fromJson(Map<String, dynamic> d) => ShiftRule(
    id:        d['id'] as String,
    classId:   d['classId'] as String,
    className: d['className'] as String? ?? '',
    shift:     ShiftType.values[(d['shift'] as int?) ?? 0],
  );
}
