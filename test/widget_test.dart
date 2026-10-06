import 'package:flutter_test/flutter_test.dart';
import 'package:palia_share_pc/main.dart';

void main() {
  testWidgets('Palia Share app loads', (WidgetTester tester) async {
    await tester.pumpWidget(const PaliaShareApp());
    expect(find.text('Palia Share'), findsWidgets);
  });
}
