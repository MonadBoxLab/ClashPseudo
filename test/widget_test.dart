import 'package:clash_pseudo/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Displays the Hello World starting screen', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Clash Pseudo'), findsOneWidget);
    expect(find.text('Hello World'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
