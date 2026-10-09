// Smoke test: the app boots to the empty state without a backend.
import 'package:flutter_test/flutter_test.dart';
import 'package:localsearch/main.dart';

void main() {
  testWidgets('shows empty state when backend is down', (tester) async {
    await tester.pumpWidget(const LocalSearchApp());
    await tester.pumpAndSettle();
    expect(find.text('Ask anything.'), findsOneWidget);
  });
}
