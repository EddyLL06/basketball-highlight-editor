import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectState _state(int from) => ProjectState(
  job: const {'state': 'completed'},
  players: const [{'id': 'p1', 'name': 'A'}],
  candidates: [
    for (var i = from; i < 8; i++)
      {'id': 'c$i', 'event_time_ms': i * 3000 + 3000, 'default_start_ms': i * 3000, 'default_end_ms': i * 3000 + 3000},
  ],
);

class _N extends ProjectNotifier {
  @override
  ProjectState build() => _state(0);
  void drop() => state = _state(1);
  @override
  Future<void> startReview(String id) async {}
  @override
  Future<String?> loadCandidatePreview(String id, int t) async => null;
}

void main() {
  testWidgets('a row with an open tooltip can move when the list reorders', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late _N notifier;
    await tester.pumpWidget(ProviderScope(
      overrides: [projectProvider.overrideWith(() => notifier = _N())],
      child: const MaterialApp(home: Scaffold(body: ReviewScreen())),
    ));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byKey(const ValueKey('player-chip-c3'))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('设置球员标签'), findsOneWidget);
    notifier.drop();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('player-chip-c3')), findsOneWidget);
  });
}
