// test/components/cs_chips_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:desktop/components/cs_status_chip.dart';
import 'package:desktop/components/cs_metric_tile.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('goal chip shows 保留 + check icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsStatusChip(status: ReviewStatus.goal),
      ),
    );
    expect(find.text('保留'), findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
  });
  testWidgets('pending and confirmed clips have the same inclusion display', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: const [
            CsStatusChip(status: ReviewStatus.pending),
            CsStatusChip(status: ReviewStatus.goal),
            CsStatusChip(status: ReviewStatus.excluded),
          ],
        ),
      ),
    );
    expect(find.text('保留'), findsNWidgets(2));
    expect(find.byIcon(LucideIcons.check), findsNWidgets(2));
    expect(find.text('排除'), findsOneWidget);
    expect(find.text('待审核'), findsNothing);
    expect(find.text('已确认'), findsNothing);
  });
  testWidgets('metric tile shows label and tabular value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsMetricTile(label: '进球', value: '4'),
      ),
    );
    expect(find.text('进球'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });
}
