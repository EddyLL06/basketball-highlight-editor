import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:desktop/core/windows_update_installer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late FileUpdateInstallSession session;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bhe-install-test-');
    session = FileUpdateInstallSession(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('does not authorize replacement until explicitly committed', () async {
    await File('${directory.path}/ready').writeAsString('ready');
    await session.waitUntilReady();
    expect(File('${directory.path}/commit').existsSync(), isFalse);
    await File('${directory.path}/accepted').writeAsString('accepted');
    await session.commit();
    expect(File('${directory.path}/commit').existsSync(), isTrue);
    await session.cancel();
    expect(File('${directory.path}/cancel').existsSync(), isTrue);
  });

  test('propagates helper errors even if the ready marker exists', () async {
    await File('${directory.path}/ready').writeAsString('ready');
    await File(
      '${directory.path}/error.txt',
    ).writeAsString('extra personal file');
    await expectLater(
      session.waitUntilReady(),
      throwsA(isA<UpdateException>()),
    );
  });

  test('a missing helper never authorizes shutdown', () async {
    await expectLater(
      session.waitUntilReady(timeout: Duration.zero),
      throwsA(isA<UpdateException>()),
    );
    expect(File('${directory.path}/commit').existsSync(), isFalse);
  });

  test('commit fails if the helper exited after becoming ready', () async {
    await File('${directory.path}/ready').writeAsString('ready');
    await session.waitUntilReady();
    await File('${directory.path}/error.txt').writeAsString('helper expired');
    await expectLater(session.commit(), throwsA(isA<UpdateException>()));
  });
}
