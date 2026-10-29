import 'package:desktop/core/engine_session.dart';
import 'package:desktop/features/review/shooter_quick_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReviewEngine {
  final saves = <JsonMap>[];
  bool rejectSave = false;

  Future<JsonMap> request(String command, JsonMap payload) async {
    if (command == 'list_shooter_review') {
      return {
        'players': [{'id': 'red', 'name': 'Red'}, {'id': 'green', 'name': 'Green'}],
        'videos': [{'id': 'video'}],
        'jobs': [],
        'candidates': [for (var i = 0; i < 2; i++) {
          'id': 'c$i', 'video_id': 'video', 'event_time_ms': 1800 + i * 2000,
          'review_status': 'excluded', 'selection_status': 'excluded',
          'player_id': null, 'shooter_review_state': 'pending',
          'shooter_selection': <String, dynamic>{},
          'shooter_evidence': {
            'generation': 'g1', 'tracking_scope': 'scope$i',
            'release_time_ms': 1100 + i * 2000, 'release_uncertain': i == 1,
            'recommended_track_id': 1,
            'frames': [for (final delta in [-100, 0, 100]) {
              'time_ms': 1100 + i * 2000 + delta,
              'context_path': null,
              'people': [{'track_id': 1, 'crop_path': null}, {'track_id': 2, 'crop_path': null}],
            }],
          },
        }],
      };
    }
    if (command == 'set_candidate_shooter') {
      if (rejectSave) throw StateError('Save failed');
      saves.add(Map.of(payload));
      return {'updated': true, 'selection': Map.of(payload), 'review_state': payload['review_state']};
    }
    throw StateError('Unexpected command: $command');
  }
}

Future<void> _pump(WidgetTester tester, _ReviewEngine engine) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: ShooterQuickLabel(request: engine.request)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('chooses person and adjacent frame, saves shooter without changing outcome', (tester) async {
    final engine = _ReviewEngine();
    await _pump(tester, engine);
    final card = find.byKey(const ValueKey('shooter-card-c0'));
    await tester.tap(find.byKey(const ValueKey('shooter-person-c0-2')));
    await tester.tap(find.descendant(of: card, matching: find.text('100 ms')));
    await tester.tap(find.byKey(const ValueKey('shooter-name-c0-green')));
    await tester.pumpAndSettle();
    expect(engine.saves.single, containsPair('track_id', 2));
    expect(engine.saves.single, containsPair('time_ms', 1200));
    expect(engine.saves.single, containsPair('player_id', 'green'));
    expect(engine.saves.single, containsPair('generation', 'g1'));
    expect(engine.saves.single.containsKey('status'), isFalse);
    expect(engine.saves.single.containsKey('outcome'), isFalse);
    expect(find.text('Shooter: Green'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save stays pending; retry and undo restore the previous label', (tester) async {
    final engine = _ReviewEngine()..rejectSave = true;
    await _pump(tester, engine);
    final name = find.byKey(const ValueKey('shooter-name-c0-red'));
    await tester.tap(name);
    await tester.pumpAndSettle();
    expect(engine.saves, isEmpty);
    expect(find.textContaining('Save failed'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    engine.rejectSave = false;
    await tester.tap(name);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(engine.saves.last['review_state'], 'pending');
    expect(engine.saves.last['player_id'], isNull);
    expect(find.text('Saved'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard label applies only to selected card; uncertain is independently persisted', (tester) async {
    final engine = _ReviewEngine();
    await _pump(tester, engine);
    await tester.tap(find.byKey(const ValueKey('shooter-person-c1-1')));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(engine.saves.single['candidate_id'], 'c1');
    expect(engine.saves.single['player_id'], 'red');
    final card = find.byKey(const ValueKey('shooter-card-c1'));
    await tester.tap(find.descendant(of: card, matching: find.widgetWithText(TextButton, 'Uncertain')));
    await tester.pumpAndSettle();
    expect(engine.saves.last['review_state'], 'uncertain');
    expect(engine.saves.last['player_id'], isNull);
    expect(tester.takeException(), isNull);
  });
}
