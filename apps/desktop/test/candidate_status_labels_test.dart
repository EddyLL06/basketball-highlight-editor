import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/review/candidate_status_labels.dart';
import 'package:desktop/theme/app_colors.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final status in ['已排除', '自动排除']) {
        testWidgets(
          'visible labels stay in one line $locale $brightness $status',
          (tester) async {
            tester.view.physicalSize = const Size(360, 180);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final colors = brightness == Brightness.dark
                ? darkAppColors
                : lightAppColors;
            Future<void> pump(bool marked) => tester.pumpWidget(
              MaterialApp(
                theme: appTheme(brightness),
                locale: Locale(locale),
                localizationsDelegates: BheLocalizations.localizationsDelegates,
                supportedLocales: BheLocalizations.supportedLocales,
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 107,
                      child: CandidateStatusLabels(
                        candidateId: 'test',
                        adjusted: marked,
                        overlapsPrevious: marked,
                        statusLabel: status,
                        statusColor: colors.error,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await pump(false);
            await tester.pumpAndSettle();
            final height = tester
                .getSize(find.byType(CandidateStatusLabels))
                .height;
            await pump(true);
            await tester.pumpAndSettle();
            final adjusted = find.text(locale == 'en' ? 'Edited' : '已调整');
            final overlap = find.text(locale == 'en' ? 'Overlap' : '重叠');
            expect(adjusted, findsOneWidget);
            expect(overlap, findsOneWidget);
            expect(tester.widget<Text>(adjusted).style!.color, colors.amber);
            expect(tester.widget<Text>(overlap).style!.color, colors.orange);
            expect(
              find.byTooltip(locale == 'en' ? 'Duration adjusted' : '已调整时长'),
              findsOneWidget,
            );
            expect(
              find.byTooltip(
                locale == 'en' ? 'Overlaps the previous kept clip' : '与上一段重叠',
              ),
              findsOneWidget,
            );
            expect(
              tester.getSize(find.byType(CandidateStatusLabels)).height,
              height,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
