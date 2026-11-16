import 'package:flutter_test/flutter_test.dart';
import 'package:strata_flutter/main.dart';

void main() {
  testWidgets('StrataApp renders side panel and map controls', (tester) async {
    await tester.pumpWidget(const StrataApp());
    await tester.pump();

    expect(find.text('Local Disk (C:)'), findsOneWidget);
    expect(find.text('气泡'), findsOneWidget);
    expect(find.text('流动'), findsOneWidget);
  });
}
