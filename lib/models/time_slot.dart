import 'education_level.dart';

class TimeSlot {
  final String id;
  final int    period;
  final String startTime;
  final String endTime;
  final EducationLevel level;
  final bool   hasFridayOverride;
  final String? fridayStart;
  final String? fridayEnd;

  TimeSlot({
    required this.id,
    required this.period,
    required this.startTime,
    required this.endTime,
    required this.level,
    this.hasFridayOverride = false,
    this.fridayStart,
    this.fridayEnd,
  });

  String get label      => 'P$period  ($startTime–$endTime)';
  String get shortLabel => 'P$period';
  String get fridayLabel => (hasFridayOverride && fridayStart != null)
      ? '$fridayStart–$fridayEnd'
      : startTime;

  TimeSlot copyWith({
    int? period,
    String? startTime,
    String? endTime,
    EducationLevel? level,
    bool? hasFridayOverride,
    String? fridayStart,
    String? fridayEnd,
  }) => TimeSlot(
    id: id,
    period:            period            ?? this.period,
    startTime:         startTime         ?? this.startTime,
    endTime:           endTime           ?? this.endTime,
    level:             level             ?? this.level,
    hasFridayOverride: hasFridayOverride ?? this.hasFridayOverride,
    fridayStart:       fridayStart       ?? this.fridayStart,
    fridayEnd:         fridayEnd         ?? this.fridayEnd,
  );

  static List<TimeSlot> defaults(EducationLevel level) {
    if (level == EducationLevel.intermediate) {
      // Intermediate: 45 min defaults starting at 8:00
      return [
        TimeSlot(id:'ts_int_1', period:1, startTime:'08:00', endTime:'08:45', level: level),
        TimeSlot(id:'ts_int_2', period:2, startTime:'08:45', endTime:'09:30', level: level),
        TimeSlot(id:'ts_int_3', period:3, startTime:'09:30', endTime:'10:15', level: level),
        TimeSlot(id:'ts_int_4', period:4, startTime:'10:15', endTime:'11:00', level: level),
        TimeSlot(id:'ts_int_5', period:5, startTime:'11:00', endTime:'11:45', level: level),
        TimeSlot(id:'ts_int_6', period:6, startTime:'11:45', endTime:'12:30', level: level),
        TimeSlot(id:'ts_int_7', period:7, startTime:'12:30', endTime:'13:15', level: level),
        TimeSlot(id:'ts_int_8', period:8, startTime:'13:15', endTime:'14:00', level: level),
      ];
    } else {
      // Bachelors: 60 min defaults starting at 8:00
      return [
        TimeSlot(id:'ts_bac_1', period:1, startTime:'08:00', endTime:'09:00', level: level),
        TimeSlot(id:'ts_bac_2', period:2, startTime:'09:00', endTime:'10:00', level: level),
        TimeSlot(id:'ts_bac_3', period:3, startTime:'10:00', endTime:'11:00', level: level),
        TimeSlot(id:'ts_bac_4', period:4, startTime:'11:00', endTime:'12:00', level: level),
        TimeSlot(id:'ts_bac_5', period:5, startTime:'12:00', endTime:'13:00', level: level),
        TimeSlot(id:'ts_bac_6', period:6, startTime:'13:00', endTime:'14:00', level: level),
      ];
    }
  }
}