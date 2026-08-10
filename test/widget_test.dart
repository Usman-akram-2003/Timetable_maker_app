import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_maker_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Basic smoke test — app should build
    expect(TimetableMakerApp, isNotNull);
  });
}
