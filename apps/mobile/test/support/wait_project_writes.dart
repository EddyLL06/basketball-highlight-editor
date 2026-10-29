import 'package:flutter_test/flutter_test.dart';

Future<void> waitProjectWrites(
  WidgetTester tester,
  Future<void> pending,
) async {
  var finished = false;
  pending.whenComplete(() => finished = true);
  for (var i = 0; i < 1000 && !finished; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(finished, isTrue, reason: 'Project writes must finish');
  await tester.pump();
}
