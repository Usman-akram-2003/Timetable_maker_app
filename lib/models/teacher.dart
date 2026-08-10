class Teacher {
  final String id;
  final String name;
  final String department;

  Teacher({
    required this.id,
    required this.name,
    this.department = '',
  });

  @override
  bool operator ==(Object other) => other is Teacher && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
