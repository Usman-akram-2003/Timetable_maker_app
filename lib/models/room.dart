enum RoomType { room, hall, other }

class Room {
  final String id;
  final String name;      // e.g. "41", "Bot L", "Main Hall"
  final RoomType type;
  final int? capacity;

  Room({
    required this.id,
    required this.name,
    required this.type,
    this.capacity,
  });

  String get typeLabel {
    switch (type) {
      case RoomType.room:  return 'Room';
      case RoomType.hall:  return 'Hall';
      case RoomType.other: return 'Other';
    }
  }
}
