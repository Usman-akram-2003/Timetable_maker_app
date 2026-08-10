import 'teacher.dart';
import 'course.dart';
import 'class_model.dart';

class Assignment {
  final String      id;
  final Teacher     teacher;
  final Course      course;
  final ClassModel  classModel;
  final int         startSlot;    // 1-based day (1=Mon … 6=Sat)
  final int         duration;     // consecutive days
  final List<int>   customDays;   // non-empty only for non-consecutive manual pick
  final String      timeSlotId;
  final String?     roomId;       // null = no room allocated
  final bool        autoAssigned;

  Assignment({
    required this.id,
    required this.teacher,
    required this.course,
    required this.classModel,
    required this.startSlot,
    required this.duration,
    required this.timeSlotId,
    this.customDays = const [],
    this.roomId,
    this.autoAssigned = false,
  });

  Assignment copyWith({
    String? id,
    Teacher? teacher,
    Course? course,
    ClassModel? classModel,
    int? startSlot,
    int? duration,
    List<int>? customDays,
    String? timeSlotId,
    String? roomId,
    bool? autoAssigned,
  }) {
    return Assignment(
      id: id ?? this.id,
      teacher: teacher ?? this.teacher,
      course: course ?? this.course,
      classModel: classModel ?? this.classModel,
      startSlot: startSlot ?? this.startSlot,
      duration: duration ?? this.duration,
      customDays: customDays ?? this.customDays,
      timeSlotId: timeSlotId ?? this.timeSlotId,
      roomId: roomId ?? this.roomId,
      autoAssigned: autoAssigned ?? this.autoAssigned,
    );
  }

  /// All day indices (1-based) this assignment occupies
  List<int> get occupiedSlots => customDays.isNotEmpty
      ? customDays
      : List.generate(duration, (i) => startSlot + i);

  bool get hasRoom => roomId != null && roomId!.isNotEmpty;

  /// Clash keys
  Set<String> get teacherKeys =>
      occupiedSlots.map((s) => '${teacher.id}__${s}__$timeSlotId').toSet();
  Set<String> get roomKeys => hasRoom
      ? occupiedSlots.map((s) => '${roomId}__${s}__$timeSlotId').toSet()
      : {};
  Set<String> get classKeys =>
      occupiedSlots.map((s) => '${classModel.id}__${s}__$timeSlotId').toSet();

  static const _dayShort = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  String get daysLabel {
    final slots = occupiedSlots;
    final days  = slots.map((s) => _dayShort[s - 1]).toList();
    if (days.length == 1) return days.first;
    // Consecutive check
    bool consecutive = true;
    for (int i = 1; i < slots.length; i++) {
      if (slots[i] != slots[i - 1] + 1) { consecutive = false; break; }
    }
    return consecutive ? '${days.first}–${days.last}' : days.join(', ');
  }

  String get slotLabel    => daysLabel;
  String get slotPreference => slotLabel;
}
