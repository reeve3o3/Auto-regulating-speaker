// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:auto_regulating_speaker/main.dart';

void main() {
  testWidgets('UWB Control App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that the app title is displayed
    expect(find.text('UWB Control'), findsOneWidget);
    
    // Verify that mode selection buttons are present
    expect(find.text('自動模式'), findsOneWidget);
    expect(find.text('自定義模式'), findsOneWidget);
    expect(find.text('手動模式'), findsOneWidget);
  });
}
