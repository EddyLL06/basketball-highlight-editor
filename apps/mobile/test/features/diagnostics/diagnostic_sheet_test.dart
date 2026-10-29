import '../../support/wait_project_writes.dart';
import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:bhe_mobile/features/diagnostics/diagnostic_report.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../support/mobile_video_fixture.dart';

class ReportBackend implements DiagnosticBackend {
  Completer<DiagnosticSnapshot>? pending;
  bool fail = false;
  @override
  Future<void> initialize(String version, String language) async {}
  @override
  Future<void> append(String message, String? key) async {}
  @override
  Future<DiagnosticSnapshot> snapshot() async {
    if (fail) throw StateError('unavailable');
    if (pending != null) return pending!.future;
    return DiagnosticSnapshot(
      environment: const {
        'app_version': '0.1.13+android.1',
        'android': '15',
        'sdk': 35,
        'manufacturer': 'Test',
        'model': 'Test model',
        'abi': 'arm64-v8a',
        'memory_total': 1024,
        'memory_available': 512,
        'storage_available': 2048,
        'screen': '360x800 @1',
        'language': 'en',
      },
      lines: List.generate(300, (i) => 'native event $i'),
      available: true,
    );
  }
}

void main() {
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());
  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('diagnostics $width $brightness $language at 1.3x', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          String? copied;
          final opened = <String>[];
          final diagnostics = MobileDiagnostics(ReportBackend());
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              localizationsDelegates: BheLocalizations.localizationsDelegates,
              supportedLocales: BheLocalizations.supportedLocales,
              theme: bheTheme(brightness),
              builder: (_, child) => MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 800),
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showMobileDiagnostics(
                      context,
                      diagnostics: diagnostics,
                      error: DiagnosticErrorRecord(
                        StateError('raw failure /private/person/game.mp4'),
                        null,
                        'export',
                      ),
                      copy: (value) async {
                        copied = value;
                      },
                      open: (value) async {
                        opened.add(value);
                        return false;
                      },
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final sheet = find.byKey(const ValueKey('diagnostics-sheet'));
          final preview = find.byKey(const ValueKey('diagnostics-preview'));
          expect(tester.getSize(sheet).height, lessThanOrEqualTo(680.1));
          expect(
            tester.getSize(preview).height,
            lessThanOrEqualTo(tester.getSize(sheet).height * .45 + .1),
          );
          final copy = find.byKey(const ValueKey('diagnostics-copy'));
          await tester.ensureVisible(copy);
          await tester.pump();
          expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
          await tester.tap(copy);
          await tester.pump();
          expect(
            find.text(language == 'en' ? 'Copied' : '已复制'),
            findsOneWidget,
          );
          expect(copied, contains('0.1.13+android.1'));
          expect(copied, contains('raw failure <path>/game.mp4'));
          expect(copied, contains('native event 299'));
          expect(copied, isNot(contains('/private/person')));
          await tester.pump(const Duration(seconds: 2));
          expect(
            find.text(language == 'en' ? 'Copy diagnostics' : '复制诊断信息'),
            findsOneWidget,
          );
          final github = find.byKey(const ValueKey('diagnostics-github'));
          await tester.ensureVisible(github);
          await tester.tap(github);
          await tester.pump();
          expect(opened.single, githubIssueUrl);
          if (language == 'en') {
            for (final text in tester.widgetList<Text>(find.byType(Text))) {
              expect(
                text.data ?? '',
                isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
              );
            }
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  test(
    'report degrades when logs fail and includes every environment field',
    () async {
      final diagnostics = MobileDiagnostics(ReportBackend());
      final report = await buildMobileDiagnosticReport(
        diagnostics,
        text: (s) => s,
        error: DiagnosticErrorRecord(
          StateError('/private/data'),
          null,
          'analysis',
        ),
      );
      for (final field in [
        'App 版本',
        '安卓版本',
        'SDK',
        '厂商',
        '手机型号',
        'CPU 架构',
        '总内存',
        '可用内存',
        '可用存储',
        '屏幕尺寸',
        '语言',
        '当前错误',
      ]) {
        expect(report, contains(field));
      }
      expect(report, isNot(contains('/private')));
      final failed = MobileDiagnostics(ReportBackend()..fail = true);
      expect(
        await buildMobileDiagnosticReport(failed, text: (s) => s),
        contains('运行日志暂不可用'),
      );
    },
  );
  testWidgets(
    'menu feedback entry follows update and failure feedback uses same sheet',
    (tester) async {
      final before = MobileDiagnostics.instance;
      MobileDiagnostics.instance = MobileDiagnostics(ReportBackend());
      addTearDown(() => MobileDiagnostics.instance = before);
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      fixture.state.project = fixture.project(
        '${fixture.root.path}/missing.mp4',
      );
      fixture.state.markVideoFailure(VideoSourceFailure.missing);
      await tester.pumpWidget(BheMobileApp(appState: fixture.state));
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.ellipsis));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('反馈与诊断')).dy,
        greaterThan(tester.getTopLeft(find.text('检查更新')).dy),
      );
      await tester.tap(find.text('反馈与诊断'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('diagnostics-sheet')), findsOneWidget);
      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pumpAndSettle();
      fixture.state.recordDiagnosticFailure(
        PlatformException(
          code: 'EXPORT_FAILED',
          message: 'RAW_TECHNICAL_DETAIL',
        ),
        null,
        operation: 'export',
      );
      fixture.state.updateSettings(fixture.state.project.settings);
      await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
      await tester.pump();
      expect(find.text('出错了：视频导出未完成，请重试。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-feedback')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        contains('当前错误'),
      );
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        contains('RAW_TECHNICAL_DETAIL'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('closing a pending report never reads a disposed context', (
    tester,
  ) async {
    final backend = ReportBackend()..pending = Completer<DiagnosticSnapshot>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMobileDiagnostics(
                context,
                diagnostics: MobileDiagnostics(backend),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    backend.pending!.complete(const DiagnosticSnapshot());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
