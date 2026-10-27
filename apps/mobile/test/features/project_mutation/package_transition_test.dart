import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in ['new', 'delete']) {
    test(
      'package export does not share stale project when $action starts during staging',
      () async {
        final f = MobileVideoFixture();
        await f.init();
        const share = MethodChannel('dev.fluttercommunity.plus/share');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        try {
          f.state.project = f.project('missing').copyWith(clearVideo: true);
          expect(await f.state.renameProject('Baseline'), isTrue);
          var shares = 0;
          messenger.setMockMethodCallHandler(share, (_) async {
            shares++;
            return 'dev.fluttercommunity.plus/share/success';
          });
          final entered = Completer<void>(), release = Completer<void>();
          var first = true;
          messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async {
              if (first) {
                first = false;
                entered.complete();
                await release.future;
              }
              return f.root.path;
            },
          );
          final export = f.state.exportProjectPackage();
          await entered.future;
          final transition = action == 'new'
              ? f.state.createNewProject()
              : f.state.clearProject();
          expect(f.state.projectTransitioning, isTrue);
          release.complete();
          await Future.wait([export, transition]);
          expect(shares, 0);
          expect(
            await Directory('${f.data.path}/package_staging/A').exists(),
            isFalse,
          );
          expect(await File('${f.data.path}/A.bhe').exists(), isFalse);
          expect(f.state.diagnosticError, isNull);
          if (action == 'delete') {
            expect(
              await File('${f.data.path}/projects/A.json').exists(),
              isFalse,
            );
          }
        } finally {
          messenger.setMockMethodCallHandler(share, null);
          await f.close();
        }
      },
    );
  }
}
